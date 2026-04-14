import SwiftUI
import UIKit

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var bleManager = BLEManager()
    @StateObject private var spotifyManager = SpotifyManager()
    @State private var showSettings = false
    @State private var showDetails = false

    private var isSceneBackground: Bool {
        scenePhase == .background
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.white
                    .ignoresSafeArea(edges: .all)
                VStack(spacing: 20) {
                    ConnectionStatusView(
                        isConnected: bleManager.isConnected,
                        cacheCount: bleManager.sdCacheEntryCount,
                        cacheCountLoading: bleManager.sdCacheCountLoading,
                        isAuthenticated: spotifyManager.isAuthenticated,
                        emphasizeBackgroundLimit: isSceneBackground
                    )

                    AlbumArtView(imageData: bleManager.currentAlbumArt)

                    if let track = spotifyManager.currentTrack {
                        NowPlayingView(track: track)
                    }

                    if bleManager.isTransferring {
                        ProgressView(value: bleManager.transferProgress)
                            .tint(.black.opacity(0.45))
                            .padding(.horizontal, 32)
                    }

                    if let err = spotifyManager.lastError {
                        Text(err)
                            .font(.caption)
                            .foregroundStyle(.black.opacity(0.55))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }

                    if spotifyManager.pollStatus == "Nothing playing" {
                        Text("If music plays on another device, open Spotify on this phone or transfer playback with Spotify Connect.")
                            .font(.caption2)
                            .foregroundStyle(.black.opacity(0.42))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 8)
                    }

                    Text("Spotify checks and new art work best with this app open. A transfer in progress can finish briefly in the background.")
                        .font(.caption2)
                        .foregroundStyle(.black.opacity(isSceneBackground ? 0.5 : 0.32))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 10)

                    DisclosureGroup(isExpanded: $showDetails) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(bleManager.statusMessage)
                                .font(.caption2)
                                .foregroundStyle(.black.opacity(0.45))
                                .frame(maxWidth: .infinity, alignment: .leading)
                            if let poll = spotifyManager.pollStatus {
                                Text(poll)
                                    .font(.caption2)
                                    .foregroundStyle(.black.opacity(0.38))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .padding(.vertical, 4)
                    } label: {
                        Text("Details")
                            .font(.footnote)
                            .foregroundStyle(.black.opacity(0.5))
                    }

                    Spacer(minLength: 0)

                    HStack(spacing: 24) {
                        Button {
                            Task { await spotifyManager.restoreSession() }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .font(.footnote)
                    .foregroundStyle(.black.opacity(0.55))
                    .buttonStyle(.plain)
                    .frame(minHeight: 44)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .navigationTitle("Spotify Display")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color.white, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.light, for: .navigationBar)
            .toolbar {
                Button { showSettings = true } label: {
                    Image(systemName: "gearshape")
                        .font(.body)
                        .foregroundStyle(.black.opacity(0.45))
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView(spotifyManager: spotifyManager, bleManager: bleManager)
            }
            .onAppear {
                AppDelegate.paintWindowsWhite()
                bleManager.startScanning()
                spotifyManager.startMonitoring(bleManager: bleManager)
            }
            .onChange(of: scenePhase) { newPhase in
                spotifyManager.scenePhaseDidChange(newPhase)
            }
            .onDisappear {
                spotifyManager.stopMonitoring()
            }
        }
        .background(Color.white.ignoresSafeArea(edges: .all))
        .preferredColorScheme(.light)
    }
}

struct ConnectionStatusView: View {
    let isConnected: Bool
    var cacheCount: Int?
    var cacheCountLoading: Bool = false
    var isAuthenticated: Bool = false
    /// When true (e.g. app in background), surface a clearer reminder that polling mostly pauses.
    var emphasizeBackgroundLimit: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Circle()
                    .fill(isConnected ? Color.black : Color.black.opacity(0.2))
                    .frame(width: 6, height: 6)
                Text(isConnected ? "Display connected" : "Looking for display…")
                    .font(.footnote)
                    .foregroundStyle(.black.opacity(0.65))
            }
            HStack(spacing: 8) {
                Circle()
                    .fill(isAuthenticated ? Color.black : Color.black.opacity(0.2))
                    .frame(width: 6, height: 6)
                Text(isAuthenticated ? "Spotify signed in" : "Spotify not signed in")
                    .font(.footnote)
                    .foregroundStyle(.black.opacity(0.65))
            }
            if isConnected {
                Group {
                    if cacheCountLoading, cacheCount == nil {
                        Text("Total cached on display: …")
                    } else if let n = cacheCount {
                        Text("Total cached on display: \(n)")
                    } else {
                        Text("Total cached on display: —")
                    }
                }
                .font(.caption2)
                .foregroundStyle(.black.opacity(0.38))
            }
            if emphasizeBackgroundLimit, isAuthenticated {
                Text("Background: Spotify updates are limited — bring the app to the foreground for live art.")
                    .font(.caption2)
                    .foregroundStyle(.black.opacity(0.48))
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct AlbumArtView: View {
    let imageData: Data?
    /// Max edge length; matches firmware 240×240 send while using available width on larger phones.
    private let maxSide: CGFloat = 280

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, maxSide)
            let placeholderSymbolSize = max(12, min(40, side * 0.16))
            ZStack {
                if let data = imageData, let uiImage = UIImage(data: data) {
                    Image(uiImage: uiImage)
                        .resizable()
                        .scaledToFill()
                        .frame(width: side, height: side)
                        .clipped()
                } else {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.black.opacity(0.04))
                    VStack(spacing: 10) {
                        Image(systemName: "music.note.list")
                            .font(.system(size: placeholderSymbolSize, weight: .ultraLight))
                            .symbolRenderingMode(.monochrome)
                            .foregroundStyle(.black.opacity(0.22))
                        Text("No art")
                            .font(.caption2)
                            .foregroundStyle(.black.opacity(0.35))
                    }
                }
            }
            .frame(width: side, height: side)
            .overlay {
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(Color.black.opacity(0.08), lineWidth: 1)
            }
            .frame(maxWidth: .infinity)
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

struct NowPlayingView: View {
    let track: Track

    var body: some View {
        VStack(spacing: 4) {
            Text(track.name)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.black.opacity(0.85))
                .multilineTextAlignment(.center)
            Text(track.artists.first?.name ?? "—")
                .font(.footnote)
                .foregroundStyle(.black.opacity(0.45))
            if let album = track.album?.name {
                Text(album)
                    .font(.caption2)
                    .foregroundStyle(.black.opacity(0.32))
            }
        }
        .padding(.vertical, 2)
    }
}

struct SettingsView: View {
    @ObservedObject var spotifyManager: SpotifyManager
    @ObservedObject var bleManager: BLEManager
    @State private var clientIDOverride = ""
    @State private var brightnessValue: Double = 200
    @State private var isClearingCache = false
    @State private var isSigningIn = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Active Client ID: \(spotifyManager.clientIdSourceDescription)")
                        .font(.subheadline)
                        .foregroundStyle(.black.opacity(0.75))

                    Button {
                        isSigningIn = true
                        Task {
                            await spotifyManager.signInWithSpotify()
                            isSigningIn = false
                        }
                    } label: {
                        HStack {
                            Spacer()
                            if isSigningIn {
                                ProgressView()
                                    .tint(.white)
                            } else {
                                Text("Sign in with Spotify")
                                    .fontWeight(.semibold)
                            }
                            Spacer()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color(red: 0.11, green: 0.73, blue: 0.33))
                    .foregroundStyle(.white)
                    .disabled(isSigningIn)

                    Button("Sign out", role: .destructive) {
                        spotifyManager.signOut()
                    }
                } header: {
                    Text("Spotify")
                        .foregroundStyle(.black.opacity(0.45))
                }

                Section {
                    Text("Default: set SpotifyClientID in the app Info.plist to your Spotify app’s Client ID (one-time per build). Optional override below without rebuilding.")
                        .font(.caption)
                        .foregroundStyle(.black.opacity(0.45))

                    TextField("Client ID override (optional)", text: $clientIDOverride)
                        .textContentType(.username)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .foregroundStyle(.black.opacity(0.85))

                    Button("Save override") {
                        spotifyManager.saveClientId(clientIDOverride)
                    }
                    .foregroundStyle(.black)

                    Button("Clear override", role: .destructive) {
                        clientIDOverride = ""
                        spotifyManager.saveClientId("")
                    }
                } header: {
                    Text("Client ID")
                        .foregroundStyle(.black.opacity(0.45))
                }

                Section {
                    HStack {
                        Text("Brightness")
                        Spacer()
                        Text("\(Int(brightnessValue))")
                            .foregroundStyle(.black.opacity(0.5))
                    }
                    Slider(value: $brightnessValue, in: 0...255, step: 1)
                        .tint(.black.opacity(0.7))
                        .onChange(of: brightnessValue) { newValue in
                            let clamped = min(255.0, max(0.0, newValue))
                            bleManager.setBrightness(UInt8(clamped))
                        }

                    Button(role: .destructive) {
                        isClearingCache = true
                    } label: {
                        Text("Clear display cache")
                    }
                    .alert("Clear display cache?", isPresented: $isClearingCache) {
                        Button("Cancel", role: .cancel) {}
                        Button("Clear", role: .destructive) {
                            Task {
                                try? await bleManager.clearDisplayCache()
                            }
                        }
                    } message: {
                        Text("This removes all cached .bin files on the display SD card.")
                    }
                } header: {
                    Text("Display")
                        .foregroundStyle(.black.opacity(0.45))
                }

                Section {
                    Text("Add redirect URI spotifydisplay://callback (exact) in the Spotify Developer Dashboard for this Client ID.")
                        .font(.caption)
                        .foregroundStyle(.black.opacity(0.45))
                    Link("Open Dashboard", destination: URL(string: "https://developer.spotify.com/dashboard")!)
                        .foregroundStyle(.black.opacity(0.65))
                } header: {
                    Text("Dashboard")
                        .foregroundStyle(.black.opacity(0.45))
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.white)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color.white, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.light, for: .navigationBar)
            .toolbar {
                Button("Done") { dismiss() }
                    .foregroundStyle(.black.opacity(0.65))
            }
            .onAppear {
                clientIDOverride = spotifyManager.storedClientIdOverride
                brightnessValue = Double(bleManager.brightness)
                AppDelegate.paintWindowsWhite()
            }
        }
        .background(Color.white.ignoresSafeArea(edges: .all))
        .preferredColorScheme(.light)
    }
}
