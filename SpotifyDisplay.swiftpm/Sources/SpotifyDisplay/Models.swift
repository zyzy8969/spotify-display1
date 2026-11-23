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
    /// A cache hit on a cover saved ahead (queue prefetch) and shown for the first time: new to the
    /// person ("new" pop-up, not "cache"). Optional so older entries decode.
    var firstShow: Bool? = nil
}

/// Spotify track ids the keychain has shown, saved on the phone. They drive the "cache" / "new" pop-up
/// words only. The light (and the app's line) follows `SavedAhead` instead (owner, 2026-11-23): blue /
/// orange flashes only for a cover the queue prefetch put on the card, never for one shown before.
/// Oldest first, capped (~110 KB at most).
enum PlayedTracks {
    static let storageKey = "playedTrackIds.v2"
    static let cap = 5000

    static func load() -> [String] {
        UserDefaults.standard.stringArray(forKey: storageKey) ?? []
    }

    static func save(_ ids: [String]) {
        UserDefaults.standard.set(Array(ids.suffix(cap)), forKey: storageKey)
    }
}

/// How the keychain's status LED behaves (BLE_PROTOCOL 1.19, 2nd byte of the ffe6 write). Saved on the
/// phone and, since 1.19, on the board too, so its power-on light follows the choice.
enum LightStyle: Int, CaseIterable, Identifiable {
    /// Calm lights: white breathing while looking for the phone, a rainbow on connect, a slow pulse in
    /// the loading colour while a cover comes and draws, one short green pulse once it is on the board, amber
    /// when disconnected.
    case consumer = 0
    /// The per-song lights: blue = cache hit, orange = new song / transfer, blue / orange flashes = saved
    /// ahead, green = done.
    case developer = 1

    var id: Int { rawValue }
    var title: String { self == .consumer ? "Consumer" : "Developer" }
    static let storageKey = "statusLightStyle"
    static var current: LightStyle {
        LightStyle(rawValue: UserDefaults.standard.integer(forKey: storageKey)) ?? .consumer
    }
}

/// The consumer loading pulse's colour (3rd byte of the ffe6 write). Same RGB as firmware `LED_LOAD_RGB`.
enum LoadingColour: Int, CaseIterable, Identifiable {
    case blue = 0, purple, white, amber, pink, teal
    // BLE_PROTOCOL 1.20 (a 1.19 board shows these as blue)
    case orange, yellow, cyan, lavender, coral
    /// The pulse also turns through the hues (0.8 s a turn).
    case rainbow

    var id: Int { rawValue }
    var title: String {
        switch self {
        case .blue: return "Blue"
        case .purple: return "Purple"
        case .white: return "White"
        case .amber: return "Amber"
        case .pink: return "Pink"
        case .teal: return "Teal"
        case .orange: return "Orange"
        case .yellow: return "Yellow"
        case .cyan: return "Cyan"
        case .lavender: return "Lavender"
        case .coral: return "Coral"
        case .rainbow: return "Rainbow"
        }
    }
    var hex: UInt32 {
        switch self {
        case .blue: return 0x0050FF
        case .purple: return 0x7A28FF
        case .white: return 0xFFFFFF
        case .amber: return 0xFFA000
        case .pink: return 0xFF3C8C
        case .teal: return 0x00D2B4
        case .orange: return 0xFF5A00
        case .yellow: return 0xFFD200
        case .cyan: return 0x00C8FF
        case .lavender: return 0xB48CFF
        case .coral: return 0xFF6450
        case .rainbow: return 0xFFFFFF  // not used: the hue turns
        }
    }
    static let storageKey = "statusLightColour"
    static var current: LoadingColour {
        LoadingColour(rawValue: UserDefaults.standard.integer(forKey: storageKey)) ?? .blue
    }
}

/// Cache-key sources of covers the queue prefetch stored on the card and that have not been drawn yet
/// ("saved ahead"). Saved on the phone so an app relaunch between the prefetch and the song keeps it.
enum SavedAhead {
    static let storageKey = "savedAheadKeySources.v1"
    static let cap = 200

    static func load() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: storageKey) ?? [])
    }

    static func save(_ keys: Set<String>) {
        UserDefaults.standard.set(Array(keys.prefix(cap)), forKey: storageKey)
    }
}

/// The board-ready RGB565 frame of every cover this app converted, on disk (Caches, ~113 KB each), so a
/// cache hit has the frame the instant the board starts drawing it: the app's transition mirror then
/// starts with the board instead of after a download + dither. Oldest files are trimmed past `cap`.
enum FrameCache {
    static let cap = 300
    private static let frameBytes = 115_200

    private static let directory: URL? = {
        guard let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        let dir = base.appendingPathComponent("frames.v1", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private static func url(for keySource: String) -> URL? {
        let name = keySource.md5Digest.map { String(format: "%02x", $0) }.joined()
        return directory?.appendingPathComponent(name + ".rgb")
    }

    static func load(_ keySource: String) -> Data? {
        guard let url = url(for: keySource), let data = try? Data(contentsOf: url),
              data.count == frameBytes else { return nil }
        return data
    }

    /// Writes off the caller's thread; the trim runs now and then, not on every save.
    static func save(_ frame: Data, for keySource: String) {
        guard frame.count == frameBytes, let url = url(for: keySource) else { return }
        DispatchQueue.global(qos: .utility).async {
            try? frame.write(to: url, options: .atomic)
            if Int.random(in: 0..<20) == 0 { trim() }
        }
    }

    private static func trim() {
        guard let dir = directory,
              let files = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.contentModificationDateKey]),
              files.count > cap else { return }
        let dated = files.map { f in
            (f, (try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
        }
        for (f, _) in dated.sorted(by: { $0.1 < $1.1 }).prefix(files.count - cap) {
            try? FileManager.default.removeItem(at: f)
        }
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
}

extension SpotifyDisplayError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .bleTransferRejected(let reason): return reason
        case .notConnected: return "Not connected to the display."
        case .conversionFailed: return "Could not convert album art."
        case .bleTimeout: return "Timed out waiting for the display."
        case .authFailed: return "Spotify sign-in failed."
        }
    }
}
