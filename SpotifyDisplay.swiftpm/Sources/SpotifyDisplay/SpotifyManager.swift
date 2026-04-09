import SwiftUI
import AuthenticationServices
import CryptoKit

private let kRefresh = "spotify_refresh_token"
private let kClientIdDefaults = "spotify_client_id"

@MainActor
final class SpotifyManager: ObservableObject {
    @Published var currentTrack: Track?
    @Published var isAuthenticated = false
    @Published var lastError: String?

    private var accessToken: String?
    private var accessExpiry: Date?
    private var monitorTask: Task<Void, Never>?

    private var pendingTrack: Track?
    private var pendingSince: Date?
    private let debounceSeconds: TimeInterval = 0.5
    private var lastSentToDisplayTrackId: String?

    private let redirectURI = "spotifydisplay://callback"
    private let presenter = SpotifyAuthPresenter()

    var clientIdStored: String {
        UserDefaults.standard.string(forKey: kClientIdDefaults) ?? ""
    }

    func saveClientId(_ id: String) {
        UserDefaults.standard.set(id, forKey: kClientIdDefaults)
    }

    /// PKCE sign-in (no client secret on device).
    func signInWithSpotify() async {
        lastError = nil
        let clientId = clientIdStored.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clientId.isEmpty else {
            lastError = "Enter Client ID in Settings"
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
                let session = ASWebAuthenticationSession(url: authURL, callbackURLScheme: "spotifydisplay") { url, error in
                    Task { @MainActor in
                        if let error {
                            cont.resume(throwing: error)
                            return
                        }
                        guard
                            let url,
                            let pieces = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
                            let c = pieces.first(where: { $0.name == "code" })?.value
                        else {
                            cont.resume(throwing: SpotifyDisplayError.authFailed)
                            return
                        }
                        cont.resume(returning: c)
                    }
                }
                session.presentationContextProvider = self.presenter
                session.prefersEphemeralWebBrowserSession = false
                if !session.start() {
                    Task { @MainActor in
                        cont.resume(throwing: SpotifyDisplayError.authFailed)
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
        monitorTask?.cancel()
        monitorTask = Task {
            await restoreSession()
            while !Task.isCancelled {
                await pollOnce(bleManager: bleManager)
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    func stopMonitoring() {
        monitorTask?.cancel()
        monitorTask = nil
    }

    private func pollOnce(bleManager: BLEManager) async {
        guard isAuthenticated else { return }

        do {
            let state = try await fetchCurrentlyPlayingWithRefresh()

            guard let item = state.item, state.isPlaying else {
                if currentTrack != nil {
                    currentTrack = nil
                }
                pendingTrack = nil
                pendingSince = nil
                return
            }

            if item.id == lastSentToDisplayTrackId { return }

            if pendingTrack?.id != item.id {
                pendingTrack = item
                pendingSince = Date()
                return
            }

            guard let since = pendingSince, Date().timeIntervalSince(since) >= debounceSeconds else { return }

            currentTrack = item

            let artURL = bestArtURL(from: item)
            guard let artURL else { return }

            do {
                try await bleManager.processTrack(imageURL: artURL)
                lastSentToDisplayTrackId = item.id
            } catch {
                lastError = error.localizedDescription
            }
        } catch {
            lastError = error.localizedDescription
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
            let retry = http.value(forHTTPHeaderField: "Retry-After").flatMap { Int($0) } ?? 60
            try await Task.sleep(nanoseconds: UInt64(retry) * 1_000_000_000)
            return try await requestCurrentlyPlaying()
        }
        if http.statusCode == 204 {
            return CurrentlyPlayingResponse(item: nil, is_playing: false)
        }
        guard (200 ... 299).contains(http.statusCode) else {
            throw SpotifyAPIError.http(http.statusCode)
        }

        return try JSONDecoder().decode(CurrentlyPlayingResponse.self, from: data)
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
