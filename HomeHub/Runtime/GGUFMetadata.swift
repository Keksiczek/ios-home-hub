import Foundation
import os

/// Read-only inspector for the GGUF header — the start of every .gguf file
/// contains a typed key/value metadata table describing the model's
/// architecture, tokenizer, chat template, native context length and more.
///
/// **Scope of this type today**:
///   - Magic + version sanity check (also exposed via
///     `ModelDownloadService.isValidGGUFHeader`).
///   - Tensor / metadata counts.
///   - Best-effort extraction of a small set of well-known string keys:
///     `general.architecture`, `general.name`, `tokenizer.chat_template`,
///     and the `*.context_length` keys.
///
/// **Why not parse everything?** GGUF's metadata KV table supports 13
/// value types including nested arrays of arrays. A complete parser is
/// ~400 LOC and the runtime doesn't need most of it yet. Today's job is
/// to provide a single, documented surface for the next architectural
/// wave (D2 — "Do NOT hard-code per-model templates if GGUF metadata
/// provides them"). When that wave lands, the parser extends here rather
/// than scattering ad-hoc readers across runtimes.
///
/// **Format reference**:
///   https://github.com/ggml-org/ggml/blob/master/docs/gguf.md
///
/// All multi-byte fields are little-endian.
struct GGUFMetadata: Sendable, Equatable {

    /// File-format version. Versions 2 and 3 are common in 2025.
    let version: UInt32
    /// Number of tensors declared in the file (weights + biases).
    let tensorCount: UInt64
    /// Number of metadata key/value pairs in the header.
    let metadataCount: UInt64

    /// Selected string-typed metadata values, keyed by their canonical
    /// GGUF key (e.g. `"general.architecture"`). Only the well-known keys
    /// listed above are populated; everything else is parsed past and
    /// discarded. A missing key maps to `nil`, not an empty string.
    let strings: [String: String]
    /// Integer-typed metadata values — `*.context_length`,
    /// `*.embedding_length`, etc.
    let integers: [String: Int64]

    // MARK: - Convenience accessors

    var architecture: String? { strings["general.architecture"] }
    var modelName:    String? { strings["general.name"] }
    var chatTemplate: String? { strings["tokenizer.chat_template"] }

    /// Native context length declared by the model, when present. Look
    /// for `<architecture>.context_length` (e.g. `llama.context_length`).
    var nativeContextLength: Int? {
        guard let arch = architecture else { return nil }
        if let v = integers["\(arch).context_length"] { return Int(v) }
        return nil
    }

    // MARK: - Errors

    enum ReadError: Error, LocalizedError {
        case openFailed(String)
        case truncated
        case badMagic
        case unsupportedVersion(UInt32)
        case unsupportedValueType(UInt32)

        var errorDescription: String? {
            switch self {
            case .openFailed(let p):           return "Could not open GGUF file: \(p)"
            case .truncated:                   return "GGUF header is truncated."
            case .badMagic:                    return "Not a GGUF file (bad magic)."
            case .unsupportedVersion(let v):   return "Unsupported GGUF version \(v)."
            case .unsupportedValueType(let t): return "Unsupported metadata value type \(t)."
            }
        }
    }

    // MARK: - Reader

    /// Reads the header of a GGUF file. Streams from disk so callers
    /// can run this on huge model files without mapping them.
    ///
    /// The parser bails as soon as it has consumed the metadata table —
    /// it never reads tensor data. Worst case it touches the first ~1 MB
    /// of the file (chat templates can be ~64 KB on Gemma 3).
    ///
    /// - Parameter url: Path to a .gguf file on local disk.
    /// - Throws: `ReadError` on I/O failure or malformed header.
    static func read(at url: URL) throws -> GGUFMetadata {
        let log = Logger(subsystem: "HomeHub", category: "GGUFMetadata")
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            throw ReadError.openFailed(url.path)
        }
        defer { try? handle.close() }

        var reader = Reader(handle: handle)

        // ---- Fixed header (24 bytes) -------------------------------------
        let magic   = try reader.readU32()
        let version = try reader.readU32()
        // 'GGUF' = 0x46554747 little-endian.
        guard magic == 0x46554747 else { throw ReadError.badMagic }
        guard (1...3).contains(version) else {
            throw ReadError.unsupportedVersion(version)
        }
        let tensorCount   = try reader.readU64()
        let metadataCount = try reader.readU64()

        // ---- Metadata KV table -------------------------------------------
        // Pick a handful of keys we actually want; ignore the rest cheaply.
        let interestingStringKeys: Set<String> = [
            "general.architecture",
            "general.name",
            "general.description",
            "tokenizer.chat_template"
        ]
        let interestingIntegerSuffixes: [String] = [
            ".context_length",
            ".embedding_length",
            ".block_count",
            ".attention.head_count"
        ]

        var strings: [String: String] = [:]
        var integers: [String: Int64] = [:]

        for _ in 0..<metadataCount {
            let key = try reader.readString()
            let valueType = try reader.readU32()
            switch GGUFValueType(rawValue: valueType) {
            case .uint8:   _ = try reader.readByteArray(count: 1)
            case .int8:    _ = try reader.readByteArray(count: 1)
            case .uint16:  _ = try reader.readByteArray(count: 2)
            case .int16:   _ = try reader.readByteArray(count: 2)
            case .uint32:
                let v = try reader.readU32()
                if interestingIntegerSuffixes.contains(where: { key.hasSuffix($0) }) {
                    integers[key] = Int64(v)
                }
            case .int32:
                let v = Int32(bitPattern: try reader.readU32())
                if interestingIntegerSuffixes.contains(where: { key.hasSuffix($0) }) {
                    integers[key] = Int64(v)
                }
            case .float32: _ = try reader.readByteArray(count: 4)
            case .bool:    _ = try reader.readByteArray(count: 1)
            case .string:
                let s = try reader.readString()
                if interestingStringKeys.contains(key) {
                    strings[key] = s
                }
            case .uint64:
                let v = try reader.readU64()
                if interestingIntegerSuffixes.contains(where: { key.hasSuffix($0) }) {
                    integers[key] = Int64(bitPattern: v)
                }
            case .int64:
                let v = Int64(bitPattern: try reader.readU64())
                if interestingIntegerSuffixes.contains(where: { key.hasSuffix($0) }) {
                    integers[key] = v
                }
            case .float64: _ = try reader.readByteArray(count: 8)
            case .array:
                try reader.skipArray()
            case .none:
                // Unknown value type — abort rather than mis-parse the
                // rest of the table. This usually means the file is
                // damaged or from a future GGUF revision.
                log.warning("GGUFMetadata: unknown value type \(valueType, privacy: .public) for key '\(key, privacy: .public)' — aborting parse")
                throw ReadError.unsupportedValueType(valueType)
            }
        }

        return GGUFMetadata(
            version: version,
            tensorCount: tensorCount,
            metadataCount: metadataCount,
            strings: strings,
            integers: integers
        )
    }

    // MARK: - GGUF value-type enum (mirrors the C header)

    private enum GGUFValueType: UInt32 {
        case uint8 = 0, int8, uint16, int16, uint32, int32, float32,
             bool, string, array, uint64, int64, float64
    }

    // MARK: - Streaming reader

    /// Lightweight wrapper around FileHandle that reads little-endian
    /// fixed-width integers and length-prefixed UTF-8 strings.
    /// Bails fast on EOF rather than returning zero bytes silently.
    private struct Reader {
        let handle: FileHandle

        mutating func readByteArray(count: Int) throws -> Data {
            let data = handle.readData(ofLength: count)
            guard data.count == count else { throw ReadError.truncated }
            return data
        }

        mutating func readU32() throws -> UInt32 {
            let d = try readByteArray(count: 4)
            // `load(as:)` requires alignment that Data's buffer doesn't
            // guarantee — use `loadUnaligned` (iOS 16+, no-op on Apple Silicon
            // but spec-correct everywhere) or fall back to byte-shift on the
            // off chance the runtime alignment is wrong.
            return d.withUnsafeBytes { raw -> UInt32 in
                let b = raw.bindMemory(to: UInt8.self)
                return UInt32(b[0]) | (UInt32(b[1]) << 8) | (UInt32(b[2]) << 16) | (UInt32(b[3]) << 24)
            }
        }

        mutating func readU64() throws -> UInt64 {
            let d = try readByteArray(count: 8)
            return d.withUnsafeBytes { raw -> UInt64 in
                let b = raw.bindMemory(to: UInt8.self)
                var v: UInt64 = 0
                for i in 0..<8 { v |= UInt64(b[i]) << (8 * i) }
                return v
            }
        }

        /// GGUF strings: u64 length followed by raw UTF-8 bytes. No NUL.
        mutating func readString() throws -> String {
            let len = try readU64()
            // Sanity-cap the length so a corrupt header can't allocate gigabytes.
            // 64 MB covers even the most absurd chat templates with headroom.
            guard len <= 64 * 1024 * 1024 else { throw ReadError.truncated }
            let bytes = try readByteArray(count: Int(len))
            return String(data: bytes, encoding: .utf8) ?? ""
        }

        /// Skips over a GGUF array value without materialising it.
        /// Array layout: u32 element type, u64 count, then `count` elements.
        mutating func skipArray() throws {
            let elementType = try readU32()
            let count = try readU64()
            guard let type = GGUFValueType(rawValue: elementType) else {
                throw ReadError.unsupportedValueType(elementType)
            }
            let scalarSize: Int? = switch type {
            case .uint8, .int8, .bool:                 1
            case .uint16, .int16:                      2
            case .uint32, .int32, .float32:            4
            case .uint64, .int64, .float64:            8
            case .string, .array:                      nil
            }
            if let fixed = scalarSize, count <= UInt64(Int.max / max(fixed, 1)) {
                _ = try readByteArray(count: fixed * Int(count))
                return
            }
            // Variable-length elements — walk through them.
            for _ in 0..<count {
                switch type {
                case .string: _ = try readString()
                case .array:  try skipArray()
                default:
                    // Unreachable given the scalarSize handling above, but
                    // keep this exhaustive so a future enum case can't slip
                    // through.
                    throw ReadError.unsupportedValueType(elementType)
                }
            }
        }
    }
}
