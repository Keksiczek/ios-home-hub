import Foundation
import os

/// Lightweight logger usable from both the host app AND the Share
/// Extension. Mirrors `HomeHub/Services/HHLogger.swift` (`HHLog`)
/// but keeps a separate subsystem-prefixed category so log messages
/// from the extension are easy to filter in Console.app.
///
/// Why not reuse `HHLog`?
/// - `HHLog` lives only in the HomeHub target; the extension would
///   either need to depend on it (forces extension to compile half
///   of HomeHub/) or duplicate it. Keeping a thin parallel API in
///   SharedKit isolates the cross-target dependency surface to
///   exactly the files we mean to share.
enum SharedKitLog {
    private static let subsystem = "cz.keksiczek.homehub"

    static let shareExtension = Logger(subsystem: subsystem, category: "shareExtension")
    static let shared        = Logger(subsystem: subsystem, category: "sharedKit")
}
