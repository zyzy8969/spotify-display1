import Foundation

/// User-facing words. Crayon speaks in lowercase, playful words ("empty it");
/// Quiet and Serif use plain sentence case ("Clear the display"), as on their artboards.
enum CopyKey {
    case stats, settings, close
    case nothingPlaying, playSomething
    case lookingForDisplay, displayReady, sending
    case idleHeading, idleLead, connectSpotify
    case brightness, showStats, showStatsHint, themeTitle
    case onTheDisplay, emptyCache, emptyCacheConfirm, signOut, signInAgain
    case spotifySignedIn, spotifySignedOut, clientID
    case notConnected, counting
    case lastTransfer, cachedWord, freshWord
    case avgCached, avgNew, savedLabel
    case phaseLookup, phaseDownload, phaseConvert, phaseSend, phaseOther
    case sinceOpened, nothingYet, liveDetails
}

extension ThemeID {
    private var playful: Bool { self == .crayon }

    func text(_ key: CopyKey) -> String {
        let p = playful
        switch key {
        case .stats: return p ? "stats" : "Stats"
        case .settings: return p ? "settings" : "Settings"
        case .close: return "Close"
        case .nothingPlaying: return p ? "nothing playing" : "Nothing playing"
        case .playSomething: return p ? "play something on spotify" : "Play something on Spotify"
        case .lookingForDisplay: return p ? "looking for your keychain" : "Looking for the display"
        case .displayReady: return p ? "keychain ready" : "Display ready"
        case .sending: return p ? "sending" : "Sending"
        case .idleHeading: return p ? "what\u{2019}s playing,\non your keys" : "What\u{2019}s playing,\non your keys"
        case .idleLead: return p ? "your password stays with spotify" : "Your password stays with Spotify."
        case .connectSpotify: return p ? "connect spotify" : "Connect Spotify"
        case .brightness: return p ? "bright" : "Brightness"
        case .showStats: return p ? "show stats" : "Detailed stats"
        case .showStatsHint:
            return p
                ? "adds general and live pages (swipe or tap) to the main screen"
                : "Adds General and Live pages to the main screen: swipe or tap to switch."
        case .themeTitle: return p ? "look" : "Theme"
        case .onTheDisplay: return p ? "on the keychain" : "On the display"
        case .emptyCache: return p ? "empty it" : "Clear display cache"
        case .emptyCacheConfirm: return "Clear the display cache?"
        case .signOut: return p ? "sign out" : "Sign out"
        case .signInAgain: return p ? "sign in again" : "Sign in again"
        case .spotifySignedIn: return p ? "spotify connected" : "Spotify connected"
        case .spotifySignedOut: return p ? "spotify not connected" : "Spotify not connected"
        case .clientID: return p ? "client id" : "Client ID"
        case .notConnected: return p ? "not connected" : "Not connected"
        case .counting: return p ? "counting\u{2026}" : "Counting\u{2026}"
        case .lastTransfer: return p ? "last one" : "Last transfer"
        case .cachedWord: return p ? "hit" : "cached"
        case .freshWord: return p ? "new" : "sent fresh"
        case .avgCached: return p ? "avg hit" : "Avg cached"
        case .avgNew: return p ? "avg new" : "Avg new"
        case .savedLabel: return p ? "saved" : "Cached"
        case .phaseLookup: return p ? "look up" : "Lookup"
        case .phaseDownload: return p ? "download" : "Download"
        case .phaseConvert: return p ? "colours" : "Convert"
        case .phaseSend: return p ? "send" : "Send"
        case .phaseOther: return p ? "waiting" : "Other"
        case .sinceOpened: return p ? "since you opened the app" : "Since you opened the app"
        case .nothingYet: return p ? "nothing sent yet" : "Nothing sent yet"
        case .liveDetails: return p ? "live details" : "Live details"
        }
    }

    /// "47 saved" / "47 cached" / "Forty-seven cached".
    func countText(_ n: Int) -> String {
        switch self {
        case .crayon:
            return "\(n) saved"
        case .quiet:
            return "\(n) cached"
        case .serif:
            let words = Self.spellOut.string(from: NSNumber(value: n)) ?? "\(n)"
            let first = String(words.prefix(1)).uppercased()
            let rest = String(words.dropFirst())
            return first + rest + " cached"
        }
    }

    /// Built once: the footer asks for the count on every render, including each progress tick.
    private static let spellOut: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .spellOut
        return formatter
    }()

    /// Seconds from milliseconds, always with its unit ("0.9s"): most timings on Stats stand
    /// alone in a row, with no label nearby to say what the number is.
    func seconds(_ ms: Int) -> String {
        String(format: "%.1f", Double(ms) / 1000.0) + "s"
    }

    /// The word after the big number on Stats: "hit" / "cached".
    func heroUnit(cacheHit: Bool) -> String {
        text(cacheHit ? .cachedWord : .freshWord)
    }

    var displayName: String {
        switch self {
        case .crayon: return "Crayon"
        case .quiet: return "Quiet"
        case .serif: return "Serif"
        }
    }

    var blurb: String {
        switch self {
        case .crayon: return "hand-drawn, white"
        case .quiet: return "dark, a little colour"
        case .serif: return "white, Times, rules"
        }
    }
}
