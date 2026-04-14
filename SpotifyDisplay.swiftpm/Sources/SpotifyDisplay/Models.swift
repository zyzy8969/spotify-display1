import Foundation

struct Track: Codable, Identifiable {
    let id: String
    let name: String
    let artists: [Artist]
    let album: Album?
}

struct Artist: Codable {
    let name: String
}

struct Album: Codable {
    let id: String?
    let name: String
    let images: [AlbumImage]
}

struct AlbumImage: Codable {
    let url: String
    let height: Int?
    let width: Int?
}

struct TransferLogEntry: Identifiable {
    let id = UUID()
    let timestamp = Date()
    let cacheHit: Bool
    let transitionName: String?
    /// Milliseconds for each phase; nil if skipped (e.g. download skipped on cache hit).
    let cacheCheckMs: Int
    let downloadMs: Int?
    let convertMs: Int?
    let uploadMs: Int?
    let totalMs: Int
    let outcome: String // "ok", "cache hit", or error description
}

enum SpotifyDisplayError: Error {
    case notConnected
    case conversionFailed
    case bleTimeout
    /// Firmware sent `ERROR:*` on Message and/or Image notify `0x02` while waiting for SUCCESS.
    case bleTransferRejected(String)
    case authFailed
    case missingClientId
}

extension SpotifyDisplayError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .bleTransferRejected(let reason): return reason
        case .notConnected: return "Not connected to the display."
        case .conversionFailed: return "Could not convert album art."
        case .bleTimeout: return "Timed out waiting for the display."
        case .authFailed: return "Spotify sign-in failed."
        case .missingClientId: return "Spotify Client ID is missing."
        }
    }
}
