import SwiftUI
import AuthenticationServices
import CryptoKit
import Network

private let kRefresh = "spotify_refresh_token"
private let kClientIdDefaults = "spotify_client_id"
private let kSpotifyClientIDPlistKey = "SpotifyClientID"

@MainActor
final class SpotifyManager: ObservableObject {
    @Published var currentTrack: Track?
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
    private var lastObservedBleReadyEpoch: UInt64 = 0
    private var lastSceneBackgroundAt: Date?

    private weak var monitoredBle: BLEManager?
    private var artSendTask: Task<Void, Never>?
    private var artInFlightTrackId: String?

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

    /// Poll interval while monitoring (~3/min). Tuned for new-track latency vs Spotify rate limits.
    private let pollIntervalSeconds: TimeInterval = 0.35
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
            URLQueryItem(name: "scope", value: "user-read-currently-playing"),
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
        rateLimitedUntil = nil
        monitoredBle?.cancelOngoingTransfer()
        artSendTask?.cancel()
        artSendTask = nil
        artInFlightTrackId = nil
        lastDisplayFailureAt = nil
        lastDisplayFailureTrackId = nil
        lastAnyDisplayFailureAt = nil
        pendingResyncAfterTransfer = false
        pollStatus = "Not authenticated"
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
                    await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                        ProcessInfo.processInfo.performExpiringActivity(withReason: "SpotifyPollRecovery") { _ in
                            Task { @MainActor in
                                await self.pollOnce(bleManager: bleManager)
                                cont.resume()
                            }
                        }
                    }
                } else {
                    pollStatus = "Offline — waiting for network"
                }
                let ns = UInt64(pollIntervalSeconds * 1_000_000_000)
                try? await Task.sleep(nanoseconds: ns)
            }
        }
    }

    func stopMonitoring() {
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
                await requestResync(reason: "scene-active-gap-\(Int(gap))", immediatePoll: gap > 1.0)
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
                    await self.requestResync(reason: "network-restored", immediatePoll: true)
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

    private func pollOnce(bleManager: BLEManager) async {
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

        do {
            pollStatus = "Polling Spotify…"
            let state = try await fetchCurrentlyPlayingWithRefresh()
            lastError = nil

            guard let item = state.item, state.isPlaying else {
                pollStatus = "Nothing playing"
                if currentTrack != nil {
                    currentTrack = nil
                }
                pendingTrack = nil
                pendingSince = nil
                bleManager.cancelOngoingTransfer()
                artSendTask?.cancel()
                artSendTask = nil
                artInFlightTrackId = nil
                lastDisplayFailureAt = nil
                lastDisplayFailureTrackId = nil
                lastAnyDisplayFailureAt = nil
                await flushPendingResyncIfNeeded()
                return
            }

            pollStatus = "Playing: \(item.name)"
            // Always update UI with the current track
            currentTrack = item

            if let inflight = artInFlightTrackId, inflight != item.id {
                bleManager.cancelOngoingTransfer()
                artSendTask?.cancel()
                artSendTask = nil
                artInFlightTrackId = nil
            }

            // Session-aware dedupe: same track can still need resend after BLE reconnect.
            let currentReadyEpoch = bleManager.readyEpoch
            if item.id == lastSentToDisplayTrackId,
               lastSentToDisplayReadyEpoch == currentReadyEpoch
            {
                return
            }

            if pendingTrack?.id != item.id {
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

            let artURL = bestArtURL(from: item)
            guard let artURL else {
                lastError = "No album art for this track"
                lastSentToDisplayTrackId = item.id
                pendingTrack = nil
                pendingSince = nil
                return
            }

            if let globalFail = lastAnyDisplayFailureAt,
               Date().timeIntervalSince(globalFail) < displayFailureGlobalBackoffSeconds
            {
                return
            }

            bleManager.cancelOngoingTransfer()
            artSendTask?.cancel()
            artSendTask = nil

            let capturedId = item.id
            let capturedURL = artURL
            let capturedName = item.name
            let ble = bleManager
            artInFlightTrackId = capturedId
            artSendTask = Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    try await ble.processTrack(
                        imageURL: capturedURL,
                        albumId: self.currentTrack?.album?.id,
                        trackId: capturedId
                    )
                    guard !Task.isCancelled else {
                        self.artInFlightTrackId = nil
                        self.artSendTask = nil
                        await self.flushPendingResyncIfNeeded()
                        return
                    }
                    if self.currentTrack?.id == capturedId {
                        self.lastError = nil
                        self.lastSentToDisplayTrackId = capturedId
                        self.lastSentToDisplayReadyEpoch = ble.readyEpoch
                        self.lastDisplayFailureAt = nil
                        self.lastDisplayFailureTrackId = nil
                        self.lastAnyDisplayFailureAt = nil
                        self.pendingTrack = nil
                        self.pendingSince = nil
                        self.artInFlightTrackId = nil
                        self.artSendTask = nil
                        self.pollStatus = "Playing: \(self.currentTrack?.name ?? capturedName)"
                        await self.flushPendingResyncIfNeeded()
                    } else {
                        // Transfer finished for `capturedId` but UI already moved — still dedupe so we do not 1 Hz resend.
                        self.lastSentToDisplayTrackId = capturedId
                        self.lastSentToDisplayReadyEpoch = ble.readyEpoch
                        self.lastDisplayFailureAt = nil
                        self.lastDisplayFailureTrackId = nil
                        self.lastAnyDisplayFailureAt = nil
                        self.pendingTrack = nil
                        self.pendingSince = nil
                        self.artInFlightTrackId = nil
                        self.artSendTask = nil
                        if let t = self.currentTrack {
                            self.pollStatus = "Playing: \(t.name)"
                        }
                        await self.flushPendingResyncIfNeeded()
                    }
                } catch let error as URLError where error.code == .cancelled {
                    self.artInFlightTrackId = nil
                    self.artSendTask = nil
                    await self.flushPendingResyncIfNeeded()
                } catch is CancellationError {
                    self.artInFlightTrackId = nil
                    self.artSendTask = nil
                    await self.flushPendingResyncIfNeeded()
                } catch {
                    self.lastError = error.localizedDescription
                    self.pollStatus = "Display transfer failed"
                    let now = Date()
                    self.lastDisplayFailureAt = now
                    self.lastDisplayFailureTrackId = capturedId
                    self.lastAnyDisplayFailureAt = now
                    // Keep current track retry-eligible; self-heal path will retry quickly.
                    if let latest = self.currentTrack {
                        self.pendingTrack = latest
                        self.pendingSince = Date().addingTimeInterval(-self.debounceSeconds)
                    } else {
                        self.pendingTrack = nil
                        self.pendingSince = nil
                    }
                    self.artInFlightTrackId = nil
                    self.artSendTask = nil
                    await self.flushPendingResyncIfNeeded()
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

    private func bestArtURL(from track: Track) -> String? {
        guard let album = track.album else { return nil }
        return album.images.max(by: { ($0.width ?? 0) < ($1.width ?? 0) })?.url
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
            return CurrentlyPlayingResponse(item: nil, isPlaying: false)
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

    private func refreshAccessToken(clientId: String, refreshToken: String) async throws {
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

    enum CodingKeys: String, CodingKey {
        case item
        case isPlaying = "is_playing"
    }
}

private enum SpotifyAPIError: Error {
    case unauthorized
    case noToken
    case badResponse
    case http(Int)
}
