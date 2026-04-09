import SwiftUI
import UIKit

struct ContentView: View {
    @StateObject private var bleManager = BLEManager()
    @StateObject private var spotifyManager = SpotifyManager()
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                ConnectionStatusView(
                    isConnected: bleManager.isConnected,
                    cacheCount: bleManager.sdCacheEntryCount
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

                Text(bleManager.statusMessage)
                    .font(.caption2)
                    .foregroundStyle(.black.opacity(0.4))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)

                Spacer(minLength: 0)

                HStack(spacing: 20) {
                    Button("Cache count") {
                        Task { try? await bleManager.refreshSDCacheCount() }
                    }
                    .disabled(!bleManager.isConnected)

                    Button {
                        Task { await spotifyManager.restoreSession() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .font(.footnote)
                .foregroundStyle(.black.opacity(0.55))
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.white)
            .navigationTitle("Spotify Display")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color.white, for: .navigationBar)
            .toolbarColorScheme(.light, for: .navigationBar)
            .toolbar {
                Button { showSettings = true } label: {
                    Image(systemName: "gearshape")
                        .font(.body)
                        .foregroundStyle(.black.opacity(0.45))
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView(spotifyManager: spotifyManager)
            }
            .onAppear {
                bleManager.startScanning()
                spotifyManager.startMonitoring(bleManager: bleManager)
            }
            .onDisappear {
                spotifyManager.stopMonitoring()
            }
        }
    }
}

struct ConnectionStatusView: View {
    let isConnected: Bool
    var cacheCount: Int?

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
            if let n = cacheCount {
                Text("Cached on device: \(n)")
                    .font(.caption2)
                    .foregroundStyle(.black.opacity(0.38))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct AlbumArtView: View {
    let imageData: Data?

    var body: some View {
        Group {
            if let data = imageData, let uiImage = UIImage(data: data) {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 240, height: 240)
                    .overlay {
                        Rectangle()
                            .strokeBorder(Color.black.opacity(0.06), lineWidth: 1)
                    }
            } else {
                ZStack {
                    Rectangle()
                        .fill(Color.white)
                        .frame(width: 240, height: 240)
                        .overlay {
                            Rectangle()
                                .strokeBorder(Color.black.opacity(0.1), lineWidth: 1)
                        }
                    VStack(spacing: 10) {
                        Image(systemName: "music.note")
                            .font(.system(size: 40, weight: .ultraLight))
                            .foregroundStyle(.black.opacity(0.22))
                        Text("No art")
                            .font(.caption2)
                            .foregroundStyle(.black.opacity(0.35))
                    }
                }
            }
        }
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
    @State private var clientID = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Client ID", text: $clientID)
                        .textContentType(.username)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .foregroundStyle(.black.opacity(0.85))

                    Button("Save Client ID") {
                        spotifyManager.saveClientId(clientID)
                    }
                    .foregroundStyle(.black)

                    Button("Sign in with Spotify") {
                        Task { await spotifyManager.signInWithSpotify() }
                    }
                    .foregroundStyle(.black)

                    Button("Sign out", role: .destructive) {
                        spotifyManager.signOut()
                    }
                } header: {
                    Text("Spotify")
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
            .toolbarColorScheme(.light, for: .navigationBar)
            .toolbar {
                Button("Done") { dismiss() }
                    .foregroundStyle(.black.opacity(0.65))
            }
            .onAppear {
                clientID = spotifyManager.clientIdStored
            }
        }
        .preferredColorScheme(.light)
    }
}
