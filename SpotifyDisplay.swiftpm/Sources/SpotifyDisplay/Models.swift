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

/// Where `BLEManager.processTrack` is for the current track (UI state only).
enum SendStage: Equatable {
    /// Nothing in flight.
    case idle
    /// Cache lookup / art download / waiting for the board; no new pixels on the display yet.
    case checking
    /// Cache miss: the new cover is known and is being converted or sent; the display keeps the
    /// previous cover until the whole new frame has arrived, then draws it with a transition.
    case preparingFresh
}

/// Codable so the latest one can be kept in `LifetimeStats.last` ("Last time" survives a relaunch).
struct TransferLogEntry: Identifiable, Codable, Equatable {
    var id = UUID()
    var timestamp = Date()
    let cacheHit: Bool
    let transitionName: String?
    /// Milliseconds for each phase; nil if skipped (e.g. download skipped on cache hit).
    let cacheCheckMs: Int
    let downloadMs: Int?
    let convertMs: Int?
    let uploadMs: Int?
    let totalMs: Int
    let outcome: String // "ok", "cache hit", or error description
    /// A cache hit on a cover the app saved to SD ahead of time this session (queue prefetch): the
    /// song is new to the person even though the board drew it from its card. Optional so older
    /// saved entries still decode.
    var prefetched: Bool? = nil
    /// A cache hit for the first song shown from its album (the cover was already on the card, e.g.
    /// prefetched): new to the person ("new" pop-up, not "cache"). Optional so older entries decode.
    var firstShow: Bool? = nil
}

/// Albums the keychain has shown at least once (Spotify album id; the track id for a song without
/// one), saved on the phone. The first song shown from an album is "new" (orange LED, "new" pop-up)
/// even when its cover is already on the card (queue prefetch); every later song from that album is
/// "cache" (blue). Oldest first, capped (~110 KB at most).
enum PlayedAlbums {
    static let storageKey = "playedAlbumIds.v1"
    static let cap = 5000

    static func load() -> [String] {
        UserDefaults.standard.stringArray(forKey: storageKey) ?? []
    }

    static func save(_ ids: [String]) {
        UserDefaults.standard.set(Array(ids.suffix(cap)), forKey: storageKey)
    }
}

/// All-time totals for Settings > Lifetime stats. Saved on the phone (UserDefaults, a few hundred
/// bytes) so they survive app restarts; `transferLog` only covers the current launch.
struct LifetimeStats: Codable, Equatable {
    var firstRecorded: Date?
    var cachedCovers = 0
    var freshCovers = 0
    var photos = 0
    var cachedMsTotal = 0
    var freshMsTotal = 0
    var fastestFreshMs: Int?
    /// How often each transition was drawn (board names, `TRANSITION:<name>`).
    var transitions: [String: Int] = [:]
    /// The latest counted transfer, for "Last time" (optional, so older saves still load).
    var last: TransferLogEntry?

    static let storageKey = "lifetimeStats.v1"

    static func load() -> LifetimeStats {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let stats = try? JSONDecoder().decode(LifetimeStats.self, from: data) else { return LifetimeStats() }
        return stats
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }

    /// Counts one finished transfer. Failed ones (any other outcome) are not counted.
    mutating func record(_ entry: TransferLogEntry) {
        switch entry.outcome {
        case "cache hit":
            cachedCovers += 1
            cachedMsTotal += max(0, entry.totalMs)
        case "ok":
            freshCovers += 1
            freshMsTotal += max(0, entry.totalMs)
            fastestFreshMs = min(fastestFreshMs ?? Int.max, max(0, entry.totalMs))
        case "photo":
            photos += 1
        default:
            return
        }
        if let name = entry.transitionName, !name.isEmpty {
            transitions[name, default: 0] += 1
        }
        last = entry
        if firstRecorded == nil { firstRecorded = Date() }
    }

    var covers: Int { cachedCovers + freshCovers }
    var hitRate: Double? { covers > 0 ? Double(cachedCovers) / Double(covers) : nil }
    var averageCachedMs: Int? { cachedCovers > 0 ? cachedMsTotal / cachedCovers : nil }
    var averageFreshMs: Int? { freshCovers > 0 ? freshMsTotal / freshCovers : nil }
    var favouriteTransition: (name: String, count: Int)? {
        guard let best = transitions.max(by: { a, b in a.value < b.value || (a.value == b.value && a.key > b.key) })
        else { return nil }
        return (best.key, best.value)
    }
}

/// One `TRANSITION:<name>` announcement from the board. A new `id` each time, so the same effect twice
/// in a row still counts as a new event.
struct TransitionEvent: Identifiable, Equatable {
    let id = UUID()
    let date = Date()
    let name: String
}

/// One line of the Live tab's terminal.
struct LogLine: Identifiable {
    enum Kind { case info, tx, rx, transition, error }
    let id = UUID()
    let date = Date()
    let kind: Kind
    let text: String
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
