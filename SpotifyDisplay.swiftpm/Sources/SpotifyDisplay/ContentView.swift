import SwiftUI
import UIKit

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var bleManager = BLEManager()
    @StateObject private var spotifyManager = SpotifyManager()
    @State private var showSettings = false

    var body: some View {
        VStack(spacing: 0) {
            // Album art — full width, square, extends into top safe area
            AlbumArtView(imageData: bleManager.currentAlbumArt)

            // Transfer progress (thin bar, seamless under art)
            if bleManager.isTransferring {
                ProgressView(value: bleManager.transferProgress)
                    .tint(.white.opacity(0.5))
                    .background(Color.white.opacity(0.08))
            } else {
                Color.clear.frame(height: 4)
            }

            // Track info
            VStack(spacing: 5) {
                if let track = spotifyManager.currentTrack {
                    Text(track.name)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                    Text(track.artists.map(\.name).joined(separator: ", "))
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.55))
                    if let album = track.album?.name {
                        Text(album)
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.3))
                    }
                    if !spotifyManager.isPlaying {
                        Text("Paused")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.55))
                    }
                } else {
                    Text(spotifyManager.isAuthenticated ? "Nothing playing" : "Not signed in")
                        .font(.title3.weight(.medium))
                        .foregroundStyle(.white.opacity(0.35))
                }

                // Cache hit / sent indicator
                if let result = bleManager.lastTransferResult {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(result.hasPrefix("Cache") ? .cyan : .green)
                            .frame(width: 5, height: 5)
                        Text(result)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.white.opacity(0.35))
                    }
                    .padding(.top, 2)
                }
                if let ack = bleManager.boardAckStatus {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(.green.opacity(0.75))
                            .frame(width: 5, height: 5)
                        Text(ack)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.white.opacity(0.4))
                    }
                }
                if let transition = bleManager.lastTransitionName {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(.purple.opacity(0.75))
                            .frame(width: 5, height: 5)
                        Text("Transition: \(transition)")
                            .font(.caption2.monospaced())
                            .foregroundStyle(.white.opacity(0.35))
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 14)

            // Playback controls
            if spotifyManager.isAuthenticated {
                PlaybackControls(spotifyManager: spotifyManager)
                    .padding(.top, 12)
            }

            Spacer(minLength: 0)

            // Inline debug log
            DebugStrip(bleManager: bleManager, spotifyManager: spotifyManager)

            // Bottom bar: status + settings
            HStack(spacing: 16) {
                StatusDot(active: bleManager.isConnected, label: "Display")
                StatusDot(active: spotifyManager.isAuthenticated, label: "Spotify")
                if let poll = spotifyManager.pollStatus, poll.contains("Rate limited") {
                    Text("Rate limited")
                        .font(.caption2)
                        .foregroundStyle(.orange.opacity(0.8))
                }
                if bleManager.isConnected, let n = bleManager.sdCacheEntryCount {
                    Text("\(n) cached")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.25))
                }
                Spacer()
                Button { showSettings = true } label: {
                    Image(systemName: "gearshape")
                        .font(.body)
                        .foregroundStyle(.white.opacity(0.35))
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 6)

            // Error
            if let err = spotifyManager.lastError {
                Text(err)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.4))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 6)
            }
        }
        .background(Color.black)
        .ignoresSafeArea()
        .sheet(isPresented: $showSettings) {
            SettingsView(spotifyManager: spotifyManager, bleManager: bleManager)
        }
        .onAppear {
            bleManager.startScanning()
            spotifyManager.startMonitoring(bleManager: bleManager)
        }
        .onChange(of: scenePhase) { newPhase in
            spotifyManager.scenePhaseDidChange(newPhase)
        }
        .onDisappear {
            spotifyManager.stopMonitoring()
        }
        .preferredColorScheme(.dark)
    }
}

// MARK: - Playback Controls

struct PlaybackControls: View {
    @ObservedObject var spotifyManager: SpotifyManager

    var body: some View {
        HStack(spacing: 36) {
            Button {
                Task { await spotifyManager.skipToPrevious() }
            } label: {
                Image(systemName: "backward.fill")
                    .font(.title3)
                    .foregroundStyle(.white.opacity(0.6))
                    .frame(width: 44, height: 44)
            }

            Button {
                Task {
                    if spotifyManager.isPlaying {
                        await spotifyManager.pause()
                    } else {
                        await spotifyManager.resume()
                    }
                }
            } label: {
                Image(systemName: spotifyManager.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title)
                    .foregroundStyle(.white.opacity(0.8))
                    .frame(width: 52, height: 52)
            }

            Button {
                Task { await spotifyManager.skipToNext() }
            } label: {
                Image(systemName: "forward.fill")
                    .font(.title3)
                    .foregroundStyle(.white.opacity(0.6))
                    .frame(width: 44, height: 44)
            }
        }
    }
}

// MARK: - Components

struct StatusDot: View {
    let active: Bool
    let label: String

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(active ? Color.green : Color.white.opacity(0.15))
                .frame(width: 6, height: 6)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.white.opacity(active ? 0.45 : 0.25))
        }
    }
}

struct AlbumArtView: View {
    let imageData: Data?

    var body: some View {
        GeometryReader { geo in
            let side = geo.size.width
            ZStack {
                if let data = imageData, let uiImage = UIImage(data: data) {
                    Image(uiImage: uiImage)
                        .resizable()
                        .scaledToFill()
                        .frame(width: side, height: side)
                        .clipped()
                } else {
                    Rectangle()
                        .fill(Color.white.opacity(0.04))
                    Image(systemName: "music.note")
                        .font(.system(size: 48, weight: .ultraLight))
                        .foregroundStyle(.white.opacity(0.12))
                }
            }
            .frame(width: side, height: side)
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

// MARK: - Inline Debug Strip

struct DebugStrip: View {
    @ObservedObject var bleManager: BLEManager
    @ObservedObject var spotifyManager: SpotifyManager

    private static let timeFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    private func s(_ ms: Int) -> String {
        String(format: "%.1fs", Double(ms) / 1000.0)
    }

    private func liveColor(_ text: String) -> Color {
        let t = text.lowercased()
        if t.contains("ble") || t.contains("ack") || t.contains("send") {
            return .cyan
        }
        if t.contains("dither") || t.contains("convert") {
            return .purple
        }
        if t.contains("download") || t.contains("cache check") {
            return .green
        }
        return .orange
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            let entries = bleManager.transferLog
            let freshEntries = entries.filter { !$0.cacheHit }
            let cacheEntries = entries.filter(\.cacheHit)
            let avgFresh = freshEntries.isEmpty ? nil : Int(freshEntries.map(\.totalMs).reduce(0, +) / freshEntries.count)
            let avgCache = cacheEntries.isEmpty ? nil : Int(cacheEntries.map(\.totalMs).reduce(0, +) / cacheEntries.count)
            let live = bleManager.currentLivePhase

            if let live {
                HStack(spacing: 0) {
                    Text("live")
                        .frame(width: 58, alignment: .leading)
                        .foregroundStyle(.orange.opacity(0.9))
                    Text(live)
                        .foregroundStyle(liveColor(live).opacity(0.85))
                    Spacer()
                }
            }

            if !entries.isEmpty {
                HStack(spacing: 0) {
                    Text("avg new")
                        .frame(width: 58, alignment: .leading)
                    Text(avgFresh.map(s) ?? "n/a")
                        .foregroundStyle(.green.opacity(0.85))
                    if !freshEntries.isEmpty {
                        Text(" over \(freshEntries.count)")
                            .foregroundStyle(.white.opacity(0.35))
                    }
                    Spacer()
                }
                HStack(spacing: 0) {
                    Text("avg hit")
                        .frame(width: 58, alignment: .leading)
                    Text(avgCache.map(s) ?? "n/a")
                        .foregroundStyle(.cyan.opacity(0.85))
                    if !cacheEntries.isEmpty {
                        Text(" over \(cacheEntries.count)")
                            .foregroundStyle(.white.opacity(0.35))
                    }
                    Spacer()
                }
            }

            // Last few transfer entries (most recent first, max 5 visible)
            let recent = entries.suffix(5).reversed()
            ForEach(Array(recent)) { entry in
                HStack(spacing: 0) {
                    Text(Self.timeFmt.string(from: entry.timestamp))
                        .frame(width: 58, alignment: .leading)
                    if entry.cacheHit {
                        Text("HIT")
                            .foregroundStyle(.cyan)
                            .frame(width: 30, alignment: .leading)
                        HStack(spacing: 0) {
                            Text("cache \(s(entry.cacheCheckMs))")
                            if let ul = entry.uploadMs { Text(" ble \(s(ul))") }
                            if let name = entry.transitionName, !name.isEmpty { Text(" tr \(name)") }
                        }
                    } else {
                        Text("NEW")
                            .foregroundStyle(.green)
                            .frame(width: 30, alignment: .leading)
                        HStack(spacing: 0) {
                            if let dl = entry.downloadMs { Text("dl \(s(dl))") }
                            if let cv = entry.convertMs { Text(" cv \(s(cv))") }
                            if let ul = entry.uploadMs { Text(" ble \(s(ul))") }
                        }
                    }
                    Spacer()
                    Text(s(entry.totalMs))
                        .foregroundStyle(.white.opacity(0.4))
                }
            }

            // Live status line
            HStack(spacing: 6) {
                Text(bleManager.statusMessage)
                    .lineLimit(1)
                if let poll = spotifyManager.pollStatus {
                    Text("·")
                    Text(poll)
                        .lineLimit(1)
                }
            }
            .foregroundStyle(.white.opacity(0.2))
        }
        .font(.system(size: 9, design: .monospaced))
        .foregroundStyle(.white.opacity(0.3))
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

// MARK: - Settings

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
                }

                Section {
                    Text("Default: set SpotifyClientID in the app Info.plist. Optional override below.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    TextField("Client ID override (optional)", text: $clientIDOverride)
                        .textContentType(.username)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)

                    Button("Save override") {
                        spotifyManager.saveClientId(clientIDOverride)
                    }

                    Button("Clear override", role: .destructive) {
                        clientIDOverride = ""
                        spotifyManager.saveClientId("")
                    }
                } header: {
                    Text("Client ID")
                }

                Section {
                    HStack {
                        Text("Brightness")
                        Spacer()
                        Text("\(Int(brightnessValue))")
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $brightnessValue, in: 0...255, step: 1)
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
                }

                Section {
                    Text("Add redirect URI spotifydisplay://callback in the Spotify Developer Dashboard.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Link("Open Dashboard", destination: URL(string: "https://developer.spotify.com/dashboard")!)
                } header: {
                    Text("Dashboard")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                Button("Done") { dismiss() }
            }
            .onAppear {
                clientIDOverride = spotifyManager.storedClientIdOverride
                brightnessValue = Double(bleManager.brightness)
            }
        }
    }
}
