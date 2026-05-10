import Foundation

/// JSON-backed queue of `IngestJob`s shared with (eventually) the
/// Share Extension via the App Group container. The host app drains
/// it; the Share Extension only ever appends.
///
/// Single-file design (`jobs.json`) is fine for the v1 volume — a
/// user might queue dozens of files between launches, not thousands.
/// If write contention with the extension becomes a problem we can
/// move to one-file-per-job under `kb/index/jobs/`, but that's a
/// future concern.
actor IngestJobStore {
    private let storage: SharedStorage
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(storage: SharedStorage) {
        self.storage = storage
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        self.encoder = encoder
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    func loadAll() throws -> [IngestJob] {
        let url = storage.indexURL.appendingPathComponent("jobs.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        return try decoder.decode([IngestJob].self, from: data)
    }

    func upsert(_ job: IngestJob) throws {
        var all = try loadAll()
        if let idx = all.firstIndex(where: { $0.id == job.id }) {
            all[idx] = job
        } else {
            all.append(job)
        }
        try write(all)
    }

    func delete(id: UUID) throws {
        var all = try loadAll()
        all.removeAll { $0.id == id }
        try write(all)
    }

    /// Pulls a batch of jobs that are ready to be processed. Order:
    /// `processing` first (a previous run was interrupted and we
    /// should resume), then `queued`/`awaitingApp` by `createdAt`.
    func fetchPending(limit: Int) throws -> [IngestJob] {
        let all = try loadAll()
        let pending = all.filter {
            switch $0.status {
            case .queued, .awaitingApp, .processing: return true
            case .indexed, .failed: return false
            }
        }
        let sorted = pending.sorted { lhs, rhs in
            if lhs.status == .processing && rhs.status != .processing { return true }
            if rhs.status == .processing && lhs.status != .processing { return false }
            return lhs.createdAt < rhs.createdAt
        }
        return Array(sorted.prefix(limit))
    }

    /// Number of pending (not indexed/failed) jobs.  Used by the
    /// scheduler to decide whether scheduling a BG task is even
    /// worth it on `applicationDidEnterBackground`.
    func pendingCount() throws -> Int {
        try loadAll().reduce(into: 0) { acc, job in
            switch job.status {
            case .queued, .awaitingApp, .processing: acc += 1
            case .indexed, .failed: break
            }
        }
    }

    private func write(_ all: [IngestJob]) throws {
        let url = storage.indexURL.appendingPathComponent("jobs.json")
        let data = try encoder.encode(all)
        try data.write(to: url, options: .atomic)
    }
}
