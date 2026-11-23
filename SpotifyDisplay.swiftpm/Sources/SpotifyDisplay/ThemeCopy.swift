import Foundation

/// User-facing words. Crayon speaks in lowercase, playful words ("empty it");
/// Quiet and Keyring use plain sentence case ("Clear display cache").
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
    case sessionLog, waitingForActivity, newestLine, lifetimeStats, transitionsRow, choose
    case summaryLast, summaryHitRate, summaryAvgNew
    case cacheHistory, lastTime, seeAll
}

extension ThemeID {
    private var playful: Bool { self == .crayon }

    func text(_ key: CopyKey) -> String {
        if self == .keyring, let words = keyringText(key) { return words }
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
        case .showStats: return p ? "nerd mode (live stats)" : "Nerd mode (live stats)"
        case .showStatsHint:
            return p
                ? "adds a terminal icon at the top. tap it to move the cover to the corner and see live details, cache history and the log"
                : "Adds a terminal icon to the top of the main screen. Tap it to move the cover to the corner and show live details, cache history and the session log."
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
        case .sessionLog: return p ? "since you opened the app" : "Session log"
        case .waitingForActivity: return p ? "waiting for activity\u{2026}" : "Waiting for activity\u{2026}"
        case .newestLine: return p ? "newest" : "Newest"
        case .lifetimeStats: return p ? "lifetime stats" : "Lifetime stats"
        case .transitionsRow: return p ? "transitions" : "Transitions"
        case .choose: return p ? "choose" : "Choose"
        case .summaryLast: return p ? "last one" : "Last"
        case .summaryHitRate: return p ? "hits" : "Cache hits"
        case .summaryAvgNew: return p ? "avg new" : "Avg new"
        case .cacheHistory: return p ? "cache history" : "Cache history"
        case .lastTime: return p ? "last time" : "Last time"
        case .seeAll: return p ? "see all" : "See all"
        }
    }

    /// Keyring's own words where they differ from Quiet's sentence case (it calls the device "your
    /// keychain", since that is what its main screen draws); nil falls through.
    private func keyringText(_ key: CopyKey) -> String? {
        switch key {
        case .lookingForDisplay: return "Looking for your keychain"
        case .displayReady: return "Keychain linked"
        case .onTheDisplay: return "On your keychain"
        case .emptyCache: return "Clear keychain cache"
        case .emptyCacheConfirm: return "Clear the keychain cache?"
        default: return nil
        }
    }

    /// "47 saved" / "47 cached" / "47 on your keys".
    func countText(_ n: Int) -> String {
        switch self {
        case .crayon:
            return "\(n) saved"
        case .quiet:
            return "\(n) cached"
        case .keyring:
            return "\(n) on your keys"
        }
    }

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
        case .keyring: return "Keyring"
        }
    }

    var blurb: String {
        switch self {
        case .crayon: return "hand-drawn, bright colours"
        case .quiet: return "calm, a little colour"
        case .keyring: return "your keychain, live"
        }
    }
}
