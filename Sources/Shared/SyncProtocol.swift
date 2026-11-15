import CryptoKit
import Foundation

/// Wire format for Mac → iPhone sync over the local network (HTTP + Bonjour).
///
///   GET  /hello            → SyncHello            (no PIN needed)
///   GET  /library          → SyncLibrary          (X-Singer-PIN header)
///   GET  /track/<syncID>   → file bytes, X-Singer-Ext tells the extension
///   POST /positions        ← [syncID: SyncPosition], → merged [syncID: SyncPosition]
enum SyncProtocol {
    static let serviceType = "_singer._tcp"
    static let pinHeader = "X-Singer-PIN"
    static let extHeader = "X-Singer-Ext"

    static func syncID(forPath path: String) -> String {
        SHA256.hash(data: Data(path.utf8)).prefix(10).map { String(format: "%02x", $0) }.joined()
    }
}

struct SyncHello: Codable {
    var name: String
    var trackCount: Int
}

struct SyncLibrary: Codable {
    var name: String
    /// Tracks with `syncID` set; `url`'s extension is the extension the file will be served with.
    var tracks: [Track]
    var positions: [String: SyncPosition]
}

struct SyncPosition: Codable, Sendable {
    var seconds: Double
    var updated: Double
}
