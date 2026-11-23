import SwiftUI
import UIKit
import AuthenticationServices
import CryptoKit
import Network

private let kRefresh = "spotify_refresh_token"
private let kClientIdDefaults = "spotify_client_id"
private let kSpotifyClientIDPlistKey = "SpotifyClientID"

@MainActor
final class SpotifyManager: ObservableObject {
    @Published var currentTrack: Track?
    @Published var isPlaying = false
    @Published var isAuthenticated = false
    @Published var lastError: String?
    @Published var pollStatus: String?

    private var accessToken: String?
    private var accessExpiry: Date?
    private var monitorTask: Task<Void, Never>?

    private var pendingTrack: Track?
    private var pendingSince: Date?
    /// Settling delay for *same* track while Spotify metadata stabilizes (skip spam). New track IDs bypass extra waits below.
    private let debounceSeconds: TimeInterval = 0.12
    private var lastSentToDisplayTrackId: String?
    private var lastSentToDisplayReadyEpoch: UInt64?
    private var lastSentToDisplayArtURL: String?
    private var lastObservedBleReadyEpoch: UInt64 = 0
    private var lastSceneBackgroundAt: Date?
    /// Every track we switched away from in the last `staleFlipBackWindowSeconds`, and when
    /// (see stale flip-back guard in `pollOnce`). Several, not one: on rapid skips A→B→C, Spotify
    /// can briefly report B *or* A again, and either would cancel C's transfer and redraw old art.
    private var recentlyReplaced: [String: Date] = [:]
    /// Serial logs (2026-11-20) show Spotify reporting the previous song again 2–3 s after a switch.
    private let staleFlipBackWindowSeconds: TimeInterval = 3.0
    /// ...and once ~4 s after (a fresh song drew, then the old one's art covered it). Going back to a
    /// song replaced within this window is acted on only if Spotify keeps reporting it.
    private let returnConfirmWindowSeconds: TimeInterval = 20.0
    /// How long every answer must agree on the "back to an earlier song" before it counts. Stale
    /// answers come interleaved with correct ones; a real "previous" holds steadily.
    private let returnConfirmHoldSeconds: TimeInterval = 1.5
    private var returnCandidateId: String?
    private var returnCandidateSince: Date?

    /// Newest Spotify `timestamp` (playback-state change time) applied so far. A later answer with an
    /// older timestamp comes from a server that has not seen the latest skip, so it is dropped.
    private var newestPlaybackTimestamp: Int64?
    /// When we started dropping older-timestamp answers. If they persist this long, accept them:
    /// the timestamp went backwards for a real reason (another device took over), not lag.
    private var olderTimestampSince: Date?
    private let olderTimestampAcceptAfterSeconds: TimeInterval = 5.0

    /// Polls overlap (0.45 s loop, board-heartbeat poll, 250 ms polls after an in-app skip), and
    /// their answers can arrive out of order. An answer older than one already applied describes
    /// playback from before it — usually the song just skipped — so it is dropped.
    private var pollSeq: UInt64 = 0
    private var lastAppliedPollSeq: UInt64 = 0

    private weak var monitoredBle: BLEManager?
    private var artSendTask: Task<Void, Never>?

    /// Prefetch (BLE_PROTOCOL 1.8): once the current song is on the board, send the next queued
    /// song's cover to the SD card without drawing, so skipping to it is a fast cache hit.
    /// Any real song change cancels it (`cancelOngoingTransfer` + this task).
    private var prefetchTask: Task<Void, Never>?
    /// Tracks whose cover was stored (or found) on the board this BLE session; reset on reconnect.
    private var prefetchedTrackIds = Set<String>()
    private var prefetchedForReadyEpoch: UInt64?
    /// The queue endpoint needs `user-read-playback-state`; tokens from before it was added get
    /// 401/403. Prefetch then stays off until the user signs in again.
    private var prefetchUnavailable = false
    private var artInFlightTrackId: String?
    /// Track ID whose album art preview was last downloaded for the app UI.
    private var lastPreviewArtTrackId: String?
    private var previewArtTask: Task<Void, Never>?
    /// Monotonic counter incremented each time a new `artSendTask` is launched.
    /// Old tasks check this before touching shared state so they don't clobber a newer task.
    private var artSendGeneration: UInt64 = 0

    /// When `requestResync` runs while a download/BLE send is active, defer full resync until the pipeline is idle.
    private var pendingResyncAfterTransfer = false
    private var pendingResyncReason: String = "deferred"

    /// After a display transfer error, do not start another send for the same track every poll (prevents BLE retry storms).
    private var lastDisplayFailureAt: Date?
    private var lastDisplayFailureTrackId: String?
    private let displayFailureCooldownSeconds: TimeInterval = 1.2
    /// After any display error, brief pause before starting a send for a *different* track (reduces hammering on bad link).
    private var lastAnyDisplayFailureAt: Date?
    private let displayFailureGlobalBackoffSeconds: TimeInterval = 0.8

    /// Poll interval while monitoring. Slightly slower to reduce API pressure while keeping responsive updates.
    private let pollIntervalSeconds: TimeInterval = 0.45
    /// After HTTP 429, skip player API calls until this time (honors Retry-After, capped).
    private var rateLimitedUntil: Date?

    private let redirectURI = "spotifydisplay://callback"
    private let presenter = SpotifyAuthPresenter()
    private var authSession: ASWebAuthenticationSession?
    private var networkMonitor: NWPathMonitor?
    private let networkQueue = DispatchQueue(label: "SpotifyDisplay.NetworkMonitor")
    private var networkIsReachable = true
    private var networkMonitorStarted = false

    /// UserDefaults override (non-empty) wins; otherwise `SpotifyClientID` from Info.plist.
    var clientIdStored: String {
        let ud = UserDefaults.standard.string(forKey: kClientIdDefaults)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !ud.isEmpty { return ud }
        if let plist = Bundle.main.object(forInfoDictionaryKey: kSpotifyClientIDPlistKey) as? String {
            return plist.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return ""
    }

    /// For Settings UI: where the active Client ID comes from.
    var clientIdSourceDescription: String {
        let ud = UserDefaults.standard.string(forKey: kClientIdDefaults)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !ud.isEmpty { return "Settings override" }
        if let plist = Bundle.main.object(forInfoDictionaryKey: kSpotifyClientIDPlistKey) as? String,
           !plist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return "Info.plist (SpotifyClientID)"
        }
        return "Not configured"
    }

    /// Raw value saved as override (for Settings text field); empty means no override.
    var storedClientIdOverride: String {
        UserDefaults.standard.string(forKey: kClientIdDefaults) ?? ""
    }

    /// Saves a per-device override; pass empty string to use Info.plist only.
    func saveClientId(_ id: String) {
        let t = id.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty {
            UserDefaults.standard.removeObject(forKey: kClientIdDefaults)
        } else {
            UserDefaults.standard.set(t, forKey: kClientIdDefaults)
        }
    }

    /// PKCE sign-in (no client secret on device).
    func signInWithSpotify() async {
        lastError = nil
        let clientId = clientIdStored.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clientId.isEmpty else {
            lastError = "Set SpotifyClientID in Info.plist or add an override in Settings."
            return
        }

        let verifier = Self.codeVerifier()
        let challenge = Self.codeChallenge(for: verifier)

        var comp = URLComponents(string: "https://accounts.spotify.com/authorize")!
        comp.queryItems = [
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            // user-read-playback-state: needed by GET /me/player/queue for cover prefetch.
            URLQueryItem(name: "scope", value: "user-read-currently-playing user-read-playback-state user-modify-playback-state"),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "code_challenge", value: challenge)
        ]

        guard let authURL = comp.url else {
            lastError = "Bad auth URL"
            return
        }

        do {
            let code = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
                // Tear down any prior session so `start()` is allowed.
                self.authSession?.cancel()
                self.authSession = nil

                let session = ASWebAuthenticationSession(url: authURL, callbackURLScheme: "spotifydisplay") { [weak self] url, error in
                    Task { @MainActor in
                        self?.authSession = nil
                        if let error {
                            cont.resume(throwing: error)
                            return
                        }
                        guard
                            let url,
                            let pieces = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
                        else {
                            cont.resume(throwing: SpotifyDisplayError.authFailed)
                            return
                        }
                        if let errItem = pieces.first(where: { $0.name == "error" })?.value {
                            let desc = pieces.first(where: { $0.name == "error_description" })?.value ?? errItem
                            cont.resume(throwing: NSError(domain: "SpotifyAuth", code: 1, userInfo: [NSLocalizedDescriptionKey: desc]))
                            return
                        }
                        guard let c = pieces.first(where: { $0.name == "code" })?.value else {
                            cont.resume(throwing: SpotifyDisplayError.authFailed)
                            return
                        }
                        cont.resume(returning: c)
                    }
                }
                self.authSession = session
                session.presentationContextProvider = self.presenter
                session.prefersEphemeralWebBrowserSession = false

                // ASWebAuthenticationSession must start on the main thread with a valid presentation anchor.
                DispatchQueue.main.async {
                    guard session.start() else {
                        self.authSession = nil
                        cont.resume(throwing: SpotifyDisplayError.authFailed)
                        return
                    }
                }
            }

            try await exchangeCode(code, clientId: clientId, verifier: verifier)
            isAuthenticated = true
            prefetchUnavailable = false  // a fresh sign-in grants the queue scope
        } catch {
            lastError = error.localizedDescription
        }
    }

    func signOut() {
        KeychainHelper.delete(account: kRefresh)
        accessToken = nil
        accessExpiry = nil
        isAuthenticated = false
        currentTrack = nil
        pendingTrack = nil
        pendingSince = nil
        lastSentToDisplayTrackId = nil
        lastSentToDisplayArtURL = nil
        rateLimitedUntil = nil
        cancelPrefetch()
        monitoredBle?.cancelOngoingTransfer()
        artSendTask?.cancel()
        artSendTask = nil
        artInFlightTrackId = nil
        lastPreviewArtTrackId = nil
        previewArtTask?.cancel()
        previewArtTask = nil
        lastDisplayFailureAt = nil
        lastDisplayFailureTrackId = nil
        lastAnyDisplayFailureAt = nil
        pendingResyncAfterTransfer = false
        pollStatus = "Not authenticated"
    }

    /// Skip to next track via Spotify Web API.
    func skipToNext() async {
        await playerCommand(endpoint: "next", method: "POST")
    }

    /// Skip to previous track via Spotify Web API.
    func skipToPrevious() async {
        await playerCommand(endpoint: "previous", method: "POST")
    }

    /// Pause playback.
    func pause() async {
        await playerCommand(endpoint: "pause", method: "PUT")
    }

    /// Resume playback.
    func resume() async {
        await playerCommand(endpoint: "play", method: "PUT")
    }

    private func playerCommand(endpoint: String, method: String) async {
        guard isAuthenticated else { return }
        do {
            try await ensureAccessTokenFresh()
            guard let token = accessToken else { return }
            var req = URLRequest(url: URL(string: "https://api.spotify.com/v1/me/player/\(endpoint)")!)
            req.httpMethod = method
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let (_, response) = try await URLSession.shared.data(for: req)
            if let http = response as? HTTPURLResponse, http.statusCode == 403 {
                lastError = "Requires premium or re-sign-in for new permissions"
            }
            // Pause/play should not force a dedupe reset + resend for the same track/art.
            if endpoint == "pause" || endpoint == "play" {
                if let ble = monitoredBle {
                    await pollOnce(bleManager: ble)
                }
            } else {
                // Next/previous: do NOT cancel or force a resync here. Spotify's currently-playing
                // endpoint keeps reporting the old track for a moment after /next, so the old forced
                // resync re-sent the OLD song and the next poll cancelled it mid-draw (half-drawn
                // frames, stray rows). Poll quickly until the track id changes instead; the normal
                // poll path then cancels in-flight work and sends the new song exactly once.
                // ("previous" more than ~3 s into a song restarts it: the id never changes, nothing to send.)
                let before = currentTrack?.id
                if let ble = monitoredBle {
                    for _ in 0 ..< 8 {
                        try? await Task.sleep(nanoseconds: 250_000_000)
                        await pollOnce(bleManager: ble)
                        if currentTrack?.id != before { break }
                    }
                }
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Use saved refresh token if present.
    func restoreSession() async {
        guard let refresh = KeychainHelper.load(account: kRefresh), !refresh.isEmpty else { return }
        let clientId = clientIdStored
        guard !clientId.isEmpty else { return }
        do {
            try await refreshAccessToken(clientId: clientId, refreshToken: refresh)
            isAuthenticated = true
        } catch {
            lastError = "Session expired — sign in again"
        }
    }

    func startMonitoring(bleManager: BLEManager) {
        monitoredBle = bleManager
        startNetworkMonitor()

        // Direct callback from BLE — fires even when background poll loop is suspended by iOS.
        bleManager.onReadyCallback = { [weak self, weak bleManager] in
            guard let self else { return }
            Task { @MainActor in
                // Mark this epoch handled so the monitor loop's epoch check below does not run a
                // second resync for the same connect (that one got queued behind the first
                // transfer and re-sent the same song after it finished).
                if let bleManager { self.lastObservedBleReadyEpoch = bleManager.readyEpoch }
                await self.requestResync(reason: "ble-ready-callback", immediatePoll: true)
            }
        }

        // Board heartbeat: the only thing that runs this app once iOS suspends it in the background.
        bleManager.onHeartbeat = { [weak self, weak bleManager] in
            guard let self, let bleManager else { return }
            Task { @MainActor in
                await self.handleBoardHeartbeat(bleManager: bleManager)
            }
        }

        monitorTask?.cancel()
        monitorTask = Task {
            await restoreSession()
            await requestResync(reason: "monitor-start", immediatePoll: false)
            while !Task.isCancelled {
                let bleEpoch = bleManager.readyEpoch
                if bleEpoch != lastObservedBleReadyEpoch {
                    lastObservedBleReadyEpoch = bleEpoch
                    await requestResync(reason: "ble-ready-\(bleEpoch)", immediatePoll: true)
                }
                if networkIsReachable {
                    // Background polling comes from the board heartbeat (`handleBoardHeartbeat`).
                    await pollOnce(bleManager: bleManager)
                } else {
                    pollStatus = "Offline — waiting for network"
                }
                let ns = UInt64(pollIntervalSeconds * 1_000_000_000)
                try? await Task.sleep(nanoseconds: ns)
            }
        }
    }

    func stopMonitoring() {
        cancelPrefetch()
        monitoredBle?.cancelOngoingTransfer()
        artSendTask?.cancel()
        artSendTask = nil
        artInFlightTrackId = nil
        lastDisplayFailureAt = nil
        lastDisplayFailureTrackId = nil
        lastAnyDisplayFailureAt = nil
        pendingResyncAfterTransfer = false
        monitorTask?.cancel()
        monitorTask = nil
        stopNetworkMonitor()
    }

    func scenePhaseDidChange(_ phase: ScenePhase) {
        switch phase {
        case .background:
            lastSceneBackgroundAt = Date()
        case .active:
            let gap = Date().timeIntervalSince(lastSceneBackgroundAt ?? .distantPast)
            Task { @MainActor in
                // Just poll: returning to the app does not change what the board shows. A forced
                // resync here was queued behind any running transfer, then wiped the dedupe and
                // re-sent the song that had just finished drawing (visible double redraw).
                // A BLE reconnect still resends, via readyEpoch.
                if gap > 1.0, let ble = monitoredBle {
                    await pollOnce(bleManager: ble)
                }
            }
        default:
            break
        }
    }

    /// True while album download (`artSendTask`) or BLE chunk transfer is in progress.
    private var transferPipelineBusy: Bool {
        artSendTask != nil || (monitoredBle?.isTransferring == true)
    }

    func requestResync(reason: String, immediatePoll: Bool = true, bypassTransferGuard: Bool = false) async {
        if !(bypassTransferGuard || transferPipelineBusy) {
            pendingResyncAfterTransfer = false
        } else if !bypassTransferGuard, transferPipelineBusy {
            pendingResyncAfterTransfer = true
            pendingResyncReason = reason
            pollStatus = "Resync queued (transfer in progress)…"
            return
        }

        pendingTrack = nil
        pendingSince = nil
        lastDisplayFailureAt = nil
        lastDisplayFailureTrackId = nil
        lastAnyDisplayFailureAt = nil
        // Force a same-track resend after reconnect/session change.
        lastSentToDisplayTrackId = nil
        lastSentToDisplayArtURL = nil
        lastSentToDisplayReadyEpoch = nil
        pollStatus = "Resyncing (\(reason))…"
        if immediatePoll, let ble = monitoredBle {
            await pollOnce(bleManager: ble)
        }
    }

    private func flushPendingResyncIfNeeded() async {
        guard pendingResyncAfterTransfer else { return }
        guard !transferPipelineBusy else { return }
        pendingResyncAfterTransfer = false
        let reason = pendingResyncReason
        await requestResync(reason: reason, immediatePoll: true, bypassTransferGuard: true)
    }

    private func startNetworkMonitor() {
        guard !networkMonitorStarted else { return }
        let monitor = NWPathMonitor()
        networkMonitor = monitor
        networkMonitorStarted = true
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                guard let self else { return }
                let reachable = path.status == .satisfied
                let wasReachable = self.networkIsReachable
                self.networkIsReachable = reachable
                if reachable && !wasReachable {
                    self.pollStatus = "Network restored — resuming"
                    // Poll only (see scenePhaseDidChange): the board's picture did not change.
                    if let ble = self.monitoredBle {
                        await self.pollOnce(bleManager: ble)
                    }
                } else if !reachable {
                    self.pollStatus = "Offline — waiting for network"
                }
            }
        }
        monitor.start(queue: networkQueue)
    }

    private func stopNetworkMonitor() {
        guard networkMonitorStarted else { return }
        networkMonitor?.cancel()
        networkMonitor = nil
        networkMonitorStarted = false
    }

    /// When the last `pollOnce` started; heartbeats skip polling if the foreground loop is keeping up.
    private var lastPollStartedAt: Date?
    private var heartbeatPollInFlight = false

    /// One Spotify poll per board heartbeat (~1 s). In the foreground the 0.45 s loop already polls, so
    /// this is skipped; in the background that loop is suspended and this is what keeps the display current.
    /// A background task covers the poll itself; `processTrack` takes its own for any transfer it starts.
    private func handleBoardHeartbeat(bleManager: BLEManager) async {
        guard !heartbeatPollInFlight else { return }
        if let last = lastPollStartedAt, Date().timeIntervalSince(last) < 0.8 { return }
        guard networkIsReachable else { return }
        heartbeatPollInFlight = true
        heartbeatBackgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "SpotifyHeartbeatPoll") { [weak self] in
            Task { @MainActor in self?.endHeartbeatBackgroundTask() }
        }
        defer {
            heartbeatPollInFlight = false
            endHeartbeatBackgroundTask()
        }
        await pollOnce(bleManager: bleManager)
    }

    private var heartbeatBackgroundTaskID: UIBackgroundTaskIdentifier = .invalid

    private func endHeartbeatBackgroundTask() {
        guard heartbeatBackgroundTaskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(heartbeatBackgroundTaskID)
        heartbeatBackgroundTaskID = .invalid
    }

    private func setIfChanged<T: Equatable>(_ keyPath: ReferenceWritableKeyPath<SpotifyManager, T>, _ value: T) {
        if self[keyPath: keyPath] != value { self[keyPath: keyPath] = value }
    }

    private func pollOnce(bleManager: BLEManager) async {
        lastPollStartedAt = Date()
        guard isAuthenticated else {
            pollStatus = "Not authenticated"
            return
        }

        if let until = rateLimitedUntil {
            if Date() < until {
                pollStatus = "Rate limited — retry soon"
                return
            }
            rateLimitedUntil = nil
        }

        pollSeq &+= 1
        let mySeq = pollSeq

        do {
            let state = try await fetchCurrentlyPlayingWithRefresh()
            guard mySeq > lastAppliedPollSeq else { return }
            lastAppliedPollSeq = mySeq
            if let ts = state.timestamp {
                if let newest = newestPlaybackTimestamp, ts < newest {
                    let since = olderTimestampSince ?? Date()
                    olderTimestampSince = since
                    if Date().timeIntervalSince(since) < olderTimestampAcceptAfterSeconds {
                        return
                    }
                }
                newestPlaybackTimestamp = ts
                olderTimestampSince = nil
            }
            setIfChanged(\.lastError, nil)

            guard let item = state.item else {
                // If we were playing and now get nil, keep currentTrack briefly so
                // the UI doesn't flash (Spotify API can return nil right after pause).
                if isPlaying || currentTrack == nil {
                    pollStatus = "Nothing playing"
                    isPlaying = false
                    currentTrack = nil
                    bleManager.clearTopTransferStatus()
                    pendingTrack = nil
                    pendingSince = nil
                    cancelPrefetch()
                    bleManager.cancelOngoingTransfer()
                    artSendTask?.cancel()
                    artSendTask = nil
                    artInFlightTrackId = nil
                    lastDisplayFailureAt = nil
                    lastDisplayFailureTrackId = nil
                    lastAnyDisplayFailureAt = nil
                } else {
                    // Was already paused — keep showing last track metadata + controls.
                    pollStatus = "Paused"
                }
                await flushPendingResyncIfNeeded()
                return
            }

            // Paused on the song the board already has (or is getting): just show "Paused" with controls.
            // A different song while paused (skipped while paused, app opened paused) falls through
            // and is sent like a playing one, so the keychain matches the app.
            if !state.isPlaying, item.id == lastSentToDisplayTrackId || item.id == artInFlightTrackId {
                setIfChanged(\.isPlaying, false)
                if currentTrack?.id != item.id { currentTrack = item }
                setIfChanged(\.pollStatus, "Paused")
                let pauseArtURLs = preferredArtURLs(from: item)
                if !pauseArtURLs.isEmpty {
                    ensureAlbumArtPreview(trackId: item.id, artURLs: pauseArtURLs, bleManager: bleManager)
                }
                return
            }

            // After a skip, Spotify can keep reporting the track we switched away from for seconds,
            // interleaved with the new one. Acting on it cancels the new song or covers its art with
            // the old cached art. Within 3 s: ignore outright. Within 20 s: act only once every
            // answer has agreed for `returnConfirmHoldSeconds` (a real "previous" does; lag does not).
            // A song not shown recently is never delayed.
            let now = Date()
            recentlyReplaced = recentlyReplaced.filter { now.timeIntervalSince($0.value) < returnConfirmWindowSeconds }
            if item.id == currentTrack?.id {
                returnCandidateId = nil  // an answer for the current song breaks any "going back" run
            } else if let replacedAt = recentlyReplaced[item.id] {
                if now.timeIntervalSince(replacedAt) < staleFlipBackWindowSeconds {
                    return
                }
                if returnCandidateId != item.id {
                    returnCandidateId = item.id
                    returnCandidateSince = now
                    return
                }
                if let since = returnCandidateSince, now.timeIntervalSince(since) < returnConfirmHoldSeconds {
                    return
                }
                returnCandidateId = nil
                recentlyReplaced[item.id] = nil
            } else {
                returnCandidateId = nil
            }
            if let previous = currentTrack?.id, previous != item.id {
                recentlyReplaced[previous] = now
            }

            // Only write on change: every @Published write redraws every observing view, ~2x a second.
            setIfChanged(\.pollStatus, state.isPlaying ? "Playing: \(item.name)" : "Paused")
            setIfChanged(\.isPlaying, state.isPlaying)
            if currentTrack?.id != item.id { currentTrack = item }

            // A photo the person uploaded is on the display: keep following Spotify for the app's own
            // screen, but send nothing until they tap "Back to Spotify".
            if bleManager.photoHold { return }

            if let inflight = artInFlightTrackId, inflight != item.id {
                cancelPrefetch()
                bleManager.cancelOngoingTransfer()
                artSendTask?.cancel()
                artSendTask = nil
                artInFlightTrackId = nil
            }

            let artURLs = preferredArtURLs(from: item)
            let currentReadyEpoch = bleManager.readyEpoch
            guard let artURL = artURLs.first else {
                if lastSentToDisplayTrackId != item.id {
                    lastError = "No album art for this track"
                }
                lastSentToDisplayTrackId = item.id
                lastSentToDisplayArtURL = nil
                lastSentToDisplayReadyEpoch = currentReadyEpoch
                pendingTrack = nil
                pendingSince = nil
                return
            }

            // Session-aware dedupe: avoid duplicate cache/send work for same track+art in same BLE epoch.
            if item.id == lastSentToDisplayTrackId,
               artURL == lastSentToDisplayArtURL,
               lastSentToDisplayReadyEpoch == currentReadyEpoch
            {
                // Either board confirmed this track, or we already know it has no art.
                if bleManager.lastConfirmedTrackId == item.id || lastSentToDisplayArtURL == nil {
                    ensureAlbumArtPreview(trackId: item.id, artURLs: artURLs, bleManager: bleManager)
                    schedulePrefetch(bleManager: bleManager, currentTrackId: item.id, currentAlbumId: item.album?.id)
                    return
                }
            }

            if pendingTrack?.id != item.id {
                bleManager.clearTopTransferStatus()
                pendingTrack = item
                // Old behavior returned here and waited a full `pollIntervalSeconds` before continuing — often +0.6s latency per new song.
                // Pretend debounce already elapsed so we can download/send in this same poll (dedupe / in-flight guards still apply).
                pendingSince = Date().addingTimeInterval(-debounceSeconds)
            }

            guard let since = pendingSince, Date().timeIntervalSince(since) >= debounceSeconds else { return }

            // Do not re-enter send while the same track is still uploading (~1 Hz poll would cancel mid-BLE).
            if artSendTask != nil, artInFlightTrackId == item.id {
                return
            }

            if let failId = lastDisplayFailureTrackId, let failAt = lastDisplayFailureAt,
               failId == item.id,
               Date().timeIntervalSince(failAt) < displayFailureCooldownSeconds
            {
                return
            }

            if let globalFail = lastAnyDisplayFailureAt,
               Date().timeIntervalSince(globalFail) < displayFailureGlobalBackoffSeconds
            {
                return
            }

            cancelPrefetch()  // the real song always wins the link
            bleManager.cancelOngoingTransfer()
            artSendTask?.cancel()
            artSendTask = nil

            if let shown = lastSentToDisplayTrackId, shown != item.id, recentlyReplaced[shown] == nil {
                recentlyReplaced[shown] = Date()
            }

            let capturedId = item.id
            let capturedURL = artURL
            // The album id must come from the song being sent, not from `currentTrack` when the task
            // runs: after a skip that is the next song, and the old art would be cached under the
            // new album's key (that album would then load the wrong picture from SD).
            let capturedAlbumId = item.album?.id
            let ble = bleManager
            artInFlightTrackId = capturedId
            artSendGeneration &+= 1
            let myGeneration = artSendGeneration
            // Take background time now, synchronously. The heartbeat poll that got us here ends its
            // own background time as soon as pollOnce returns, before this task would start; iOS
            // could suspend the app in that gap and freeze the transfer after a few rows.
            ble.holdTransferBackgroundTime()
            artSendTask = Task { @MainActor [weak self] in
                defer { ble.releaseTransferBackgroundTime() }
                guard let self else { return }
                do {
                    try await ble.processTrack(
                        imageURLs: Array(artURLs.prefix(2)),
                        albumId: capturedAlbumId,
                        trackId: capturedId
                    )
                    guard self.artSendGeneration == myGeneration else { return }
                    let cancelled = Task.isCancelled
                    let sentIsCurrent = !cancelled && self.currentTrack?.id == capturedId
                    if !cancelled {
                        // Pause/stop clears `currentTrack` before this finishes: then no dedupe mark, or
                        // the next play would think the art was already sent and skip it.
                        if let current = self.currentTrack {
                            // Mark sent even if the UI already moved on, so the 1 Hz poll does not resend it.
                            self.lastSentToDisplayTrackId = capturedId
                            self.lastSentToDisplayArtURL = capturedURL
                            self.lastSentToDisplayReadyEpoch = ble.readyEpoch
                            self.lastDisplayFailureAt = nil
                            self.lastDisplayFailureTrackId = nil
                            self.lastAnyDisplayFailureAt = nil
                            if sentIsCurrent { self.lastError = nil }
                            self.pollStatus = self.isPlaying ? "Playing: \(current.name)" : "Paused"
                        }
                        self.pendingTrack = nil
                        self.pendingSince = nil
                    }
                    await self.finishSend()
                    // The current song is on the board: use the idle link for the next one.
                    if sentIsCurrent {
                        self.schedulePrefetch(bleManager: ble, currentTrackId: capturedId,
                                              currentAlbumId: capturedAlbumId)
                    }
                } catch let error where error is CancellationError || (error as? URLError)?.code == .cancelled {
                    guard self.artSendGeneration == myGeneration else { return }
                    await self.finishSend()
                } catch {
                    guard self.artSendGeneration == myGeneration else { return }
                    if let displayError = error as? SpotifyDisplayError {
                        switch displayError {
                        case .bleTimeout, .bleTransferRejected:
                            ble.cancelOngoingTransfer()
                            try? await Task.sleep(nanoseconds: 200_000_000)
                            guard self.artSendGeneration == myGeneration else { return }
                        case .notConnected, .conversionFailed, .authFailed:
                            break
                        }
                    }
                    self.recordSendFailure(trackId: capturedId, error: error)
                    await self.finishSend()
                }
            }
        } catch {
            if let e = error as? SpotifyAPIError, case .http(429) = e {
                lastError = "Spotify rate limited — pausing requests"
                pollStatus = "Rate limited — retry soon"
            } else if let urlError = error as? URLError,
                      [.notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotFindHost, .cannotConnectToHost].contains(urlError.code) {
                lastError = "Network unavailable — auto-retrying"
                pollStatus = "Offline — waiting for network"
            } else {
                lastError = error.localizedDescription
                pollStatus = "Spotify request failed"
            }
        }
    }

    /// Shared exit for every `artSendTask` outcome: frees the slot and runs any resync queued behind it.
    private func finishSend() async {
        artInFlightTrackId = nil
        artSendTask = nil
        await flushPendingResyncIfNeeded()
    }

    /// After a failed send: show the error, start both cooldowns, and queue the current song for a retry.
    private func recordSendFailure(trackId: String, error: Error) {
        lastError = error.localizedDescription
        pollStatus = "Display transfer failed"
        let now = Date()
        lastDisplayFailureAt = now
        lastDisplayFailureTrackId = trackId
        lastAnyDisplayFailureAt = now
        pendingTrack = currentTrack
        pendingSince = currentTrack == nil ? nil : now.addingTimeInterval(-debounceSeconds)
    }

    private func preferredArtURLs(from track: Track) -> [String] {
        guard let album = track.album else { return [] }
        var ranked = album.images.filter { !$0.url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !ranked.isEmpty else { return [] }

        // Prefer exact 300x300 first, then largest available (or first valid URL if sizes are missing).
        ranked.sort { lhs, rhs in
            let lExact = (lhs.width == 300 && lhs.height == 300)
            let rExact = (rhs.width == 300 && rhs.height == 300)
            if lExact != rExact { return lExact && !rExact }
            let lArea = (lhs.width ?? 0) * (lhs.height ?? 0)
            let rArea = (rhs.width ?? 0) * (rhs.height ?? 0)
            if lArea != rArea { return lArea > rArea }
            return lhs.url < rhs.url
        }

        var out: [String] = []
        var seen = Set<String>()
        for img in ranked {
            let u = img.url.trimmingCharacters(in: .whitespacesAndNewlines)
            if !u.isEmpty, !seen.contains(u) {
                out.append(u)
                seen.insert(u)
            }
        }
        return out
    }

    // MARK: - Prefetch (BLE_PROTOCOL 1.8)

    /// The current song a prefetch was last started for, so the 0.45 s poll doesn't re-read the queue.
    private var prefetchAttemptedForTrackId: String?
    private var prefetchGeneration: UInt64 = 0

    private func cancelPrefetch() {
        prefetchTask?.cancel()
        prefetchTask = nil
    }

    /// How many upcoming queue entries to put on the board ahead of time. Each costs one probe
    /// (~50 ms) when already cached, or one compressed store-only transfer when not.
    private let prefetchDepth = 5

    /// Sends the covers of the next `prefetchDepth` queued songs to the board's SD card (not drawn),
    /// nearest first. Runs at most once per current song, only when no real send is in flight. Failures are silent: prefetch is an
    /// optimisation, the normal path still sends the cover when the song starts.
    private func schedulePrefetch(bleManager: BLEManager, currentTrackId: String, currentAlbumId: String?) {
        if prefetchedForReadyEpoch != bleManager.readyEpoch {
            // New BLE session: the board may have been reflashed or its cache cleared. Forget what
            // was prefetched, including "already tried for this song", so a mid-song reconnect retries.
            prefetchedTrackIds.removeAll()
            prefetchAttemptedForTrackId = nil
            prefetchedForReadyEpoch = bleManager.readyEpoch
        }
        guard !prefetchUnavailable, prefetchTask == nil, artSendTask == nil,
              prefetchAttemptedForTrackId != currentTrackId else { return }
        // Locked / backgrounded: iOS keeps the app alive only on borrowed background time. Prefetch is
        // optional, so skip it when little is left and let the next heartbeat (fresh budget) retry —
        // the real song's send must never be starved. Not marked as attempted, so it does retry.
        let app = UIApplication.shared
        if app.applicationState != .active, app.backgroundTimeRemaining < 15 { return }
        prefetchAttemptedForTrackId = currentTrackId
        prefetchGeneration &+= 1
        let myGen = prefetchGeneration
        // Hold background time for the whole prefetch (1 s wait + queue read + transfer), taken now,
        // synchronously: the poll that got us here ends its own background time when it returns, and
        // a prefetch suspended mid-way would stall until the next wake-up.
        bleManager.holdTransferBackgroundTime()
        prefetchTask = Task { @MainActor [weak self] in
            defer { bleManager.releaseTransferBackgroundTime() }
            // Only clear the slot if it is still ours: a cancelled older prefetch finishing late must
            // not orphan a newer one (it could then never be cancelled by a song change).
            defer { if let self, self.prefetchGeneration == myGen { self.prefetchTask = nil } }
            // Let the board finish saving the current cover, and let a quick follow-up skip win.
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard let self, !Task.isCancelled, self.artSendTask == nil else { return }
            guard let queue = try? await self.fetchQueue(), !Task.isCancelled else { return }
            // Upcoming songs with art whose cover isn't already known to be on the board, nearest first.
            // Same album = same cache key, so one per album, and none for the current song's album.
            var albumsSeen = Set<String>()
            if let currentAlbumId { albumsSeen.insert(currentAlbumId) }
            var targets: [Track] = []
            for t in queue.prefix(self.prefetchDepth * 3) where targets.count < self.prefetchDepth {
                guard t.id != currentTrackId, !self.prefetchedTrackIds.contains(t.id),
                      !self.preferredArtURLs(from: t).isEmpty else { continue }
                if let a = t.album?.id {
                    guard albumsSeen.insert(a).inserted else { continue }
                }
                targets.append(t)
            }
            for next in targets {
                // A real send started (song change) or it got cancelled: stop, the real song wins.
                guard !Task.isCancelled, self.artSendTask == nil else { return }
                // Locked: stop while there's still background time for the real song's send.
                let app = UIApplication.shared
                if app.applicationState != .active, app.backgroundTimeRemaining < 10 { return }
                do {
                    _ = try await bleManager.prefetchTrack(imageURLs: Array(self.preferredArtURLs(from: next).prefix(2)),
                                                           albumId: next.album?.id)
                    self.prefetchedTrackIds.insert(next.id)
                } catch {
                    // Cancelled by a real song change: stop. Other hiccups: that song is sent
                    // normally when it starts; keep going with the rest.
                    if Task.isCancelled || error is CancellationError { return }
                }
            }
        }
    }

    private func fetchQueue() async throws -> [Track] {
        try await ensureAccessTokenFresh()
        guard let token = accessToken else { throw SpotifyAPIError.noToken }
        var req = URLRequest(url: URL(string: "https://api.spotify.com/v1/me/player/queue")!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw SpotifyAPIError.badResponse }
        if http.statusCode == 401 || http.statusCode == 403 {
            // Token from before the queue scope was added. Off until the next sign-in.
            prefetchUnavailable = true
            return []
        }
        guard (200 ... 299).contains(http.statusCode) else { return [] }
        return (try? JSONDecoder().decode(QueueResponse.self, from: data))?.queue ?? []
    }

    /// Downloads album art for the app preview if not already showing for this track.
    private func ensureAlbumArtPreview(trackId: String, artURLs: [String], bleManager: BLEManager) {
        guard lastPreviewArtTrackId != trackId || bleManager.currentAlbumArt == nil else { return }
        previewArtTask?.cancel()
        lastPreviewArtTrackId = trackId
        previewArtTask = Task { @MainActor [weak self] in
            for candidate in artURLs.prefix(2) {
                guard let url = URL(string: candidate) else { continue }
                do {
                    let (data, response) = try await URLSession.shared.data(from: url)
                    guard !Task.isCancelled else { return }
                    if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) { continue }
                    guard UIImage(data: data) != nil else { continue }
                    bleManager.currentAlbumArt = data
                    return
                } catch {
                    continue
                }
            }
            // All URLs failed — clear the stale preview marker so next poll retries.
            self?.lastPreviewArtTrackId = nil
        }
    }

    private func fetchCurrentlyPlayingWithRefresh() async throws -> CurrentlyPlayingResponse {
        try await ensureAccessTokenFresh()
        do {
            return try await requestCurrentlyPlaying()
        } catch SpotifyAPIError.unauthorized {
            let clientId = clientIdStored
            guard let refresh = KeychainHelper.load(account: kRefresh), !clientId.isEmpty else { throw SpotifyAPIError.unauthorized }
            try await refreshAccessToken(clientId: clientId, refreshToken: refresh)
            return try await requestCurrentlyPlaying()
        }
    }

    /// Refreshes access token before expiry so polling does not rely only on HTTP 401.
    private func ensureAccessTokenFresh() async throws {
        guard let exp = accessExpiry else { return }
        guard Date() >= exp else { return }
        let clientId = clientIdStored
        guard let refresh = KeychainHelper.load(account: kRefresh), !clientId.isEmpty else {
            throw SpotifyAPIError.noToken
        }
        try await refreshAccessToken(clientId: clientId, refreshToken: refresh)
    }

    private func requestCurrentlyPlaying() async throws -> CurrentlyPlayingResponse {
        guard let token = accessToken else { throw SpotifyAPIError.noToken }

        var req = URLRequest(url: URL(string: "https://api.spotify.com/v1/me/player/currently-playing")!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw SpotifyAPIError.badResponse }

        if http.statusCode == 401 { throw SpotifyAPIError.unauthorized }
        if http.statusCode == 429 {
            let wait = Self.cappedRetryAfterSeconds(from: http)
            rateLimitedUntil = Date().addingTimeInterval(wait)
            throw SpotifyAPIError.http(429)
        }
        if http.statusCode == 204 {
            rateLimitedUntil = nil
            return CurrentlyPlayingResponse(item: nil, isPlaying: false, timestamp: nil)
        }
        guard (200 ... 299).contains(http.statusCode) else {
            throw SpotifyAPIError.http(http.statusCode)
        }

        rateLimitedUntil = nil
        return try JSONDecoder().decode(CurrentlyPlayingResponse.self, from: data)
    }

    /// Parses Retry-After (seconds), clamped so a bad header cannot stall the app for hours.
    private static func cappedRetryAfterSeconds(from http: HTTPURLResponse) -> TimeInterval {
        let header = http.value(forHTTPHeaderField: "Retry-After").flatMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        let raw = header ?? 60
        return min(max(raw, 1), 120)
    }

    private func exchangeCode(_ code: String, clientId: String, verifier: String) async throws {
        var req = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let body = [
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": redirectURI,
            "client_id": clientId,
            "code_verifier": verifier
        ]
        req.httpBody = Self.formEncode(body).data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200 ... 299).contains(http.statusCode) else {
            throw SpotifyDisplayError.authFailed
        }

        let tr = try JSONDecoder().decode(TokenResponse.self, from: data)
        accessToken = tr.access_token
        if let sec = tr.expires_in {
            accessExpiry = Date().addingTimeInterval(TimeInterval(sec - 60))
        }
        if let rt = tr.refresh_token {
            KeychainHelper.save(rt, account: kRefresh)
        }
    }

    /// In-flight refresh shared by every caller. Spotify rotates refresh tokens, so two concurrent
    /// refreshes with the same token make the loser fail with `invalid_grant` (looks like a random
    /// sign-out, typically at BLE reconnect when resync and the poll loop both refresh).
    private var tokenRefreshTask: Task<Void, Error>?

    private func refreshAccessToken(clientId: String, refreshToken: String) async throws {
        if let inFlight = tokenRefreshTask {
            return try await inFlight.value
        }
        let task = Task { @MainActor in
            try await self.performTokenRefresh(clientId: clientId, refreshToken: refreshToken)
        }
        tokenRefreshTask = task
        defer { tokenRefreshTask = nil }
        try await task.value
    }

    private func performTokenRefresh(clientId: String, refreshToken: String) async throws {
        var req = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let body = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": clientId
        ]
        req.httpBody = Self.formEncode(body).data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw SpotifyDisplayError.authFailed }
        guard (200 ... 299).contains(http.statusCode) else {
            // `accessExpiry` stays in the past, so without this every 0.45 s poll would refresh again.
            if http.statusCode == 400 || http.statusCode == 401 {
                // invalid_grant / invalid_client: the refresh token is revoked or dead. Retrying never
                // works, so go back to the sign-in screen instead of looking signed in forever.
                signOut()
            } else {
                // Spotify-side trouble (5xx, 429): back off instead of hammering the token endpoint.
                rateLimitedUntil = Date().addingTimeInterval(10)
            }
            throw SpotifyDisplayError.authFailed
        }

        let tr = try JSONDecoder().decode(TokenResponse.self, from: data)
        accessToken = tr.access_token
        if let sec = tr.expires_in {
            accessExpiry = Date().addingTimeInterval(TimeInterval(sec - 60))
        }
        if let rt = tr.refresh_token {
            KeychainHelper.save(rt, account: kRefresh)
        }
    }

    private static func formEncode(_ dict: [String: String]) -> String {
        dict.map { key, val in
            let k = key.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? key
            let v = val.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? val
            return "\(k)=\(v)"
        }.joined(separator: "&")
    }

    private static func codeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func codeChallenge(for verifier: String) -> String {
        let hash = SHA256.hash(data: Data(verifier.utf8))
        return Data(hash).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

// MARK: - API types

private struct TokenResponse: Codable {
    let access_token: String
    let token_type: String?
    let expires_in: Int?
    let refresh_token: String?
}

struct CurrentlyPlayingResponse: Codable {
    let item: Track?
    let isPlaying: Bool
    /// Unix ms when Spotify last changed playback state (play, pause, skip, new song…). Used to drop
    /// answers from a lagging Spotify server that still describes the song before a skip.
    let timestamp: Int64?

    enum CodingKeys: String, CodingKey {
        case item
        case isPlaying = "is_playing"
        case timestamp
    }
}

/// `GET /v1/me/player/queue`. Items can be podcast episodes, which don't decode as `Track`; those
/// are skipped instead of failing the whole response.
struct QueueResponse: Decodable {
    let queue: [Track]

    private struct Lossy: Decodable {
        let track: Track?
        init(from decoder: Decoder) throws { track = try? Track(from: decoder) }
    }

    enum CodingKeys: String, CodingKey { case queue }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        queue = (try c.decodeIfPresent([Lossy].self, forKey: .queue) ?? []).compactMap(\.track)
    }
}

private enum SpotifyAPIError: Error {
    case unauthorized
    case noToken
    case badResponse
    case http(Int)
}
