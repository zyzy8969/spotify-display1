import SwiftUI
import UIKit

/// Root view. Owns the two managers (behaviour unchanged from before the theme work) and picks
/// the screen; every screen reads its look from `\.theme`.
///
/// Safe areas: only the background ignores them. All controls sit inside the safe area, so the
/// header clears the status bar / Dynamic Island and the bottom row clears the home indicator.
struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var bleManager = BLEManager()
    @StateObject private var spotifyManager = SpotifyManager()
    @State private var panel: Panel?
    @AppStorage(ThemeID.storageKey) private var themeRaw = ThemeID.fallback.rawValue
    /// Night switch per theme (Settings > Theme). Keys and defaults match `ThemeID.darkKey/defaultDark`.
    @AppStorage("uiDark.crayon") private var crayonDark = false
    @AppStorage("uiDark.quiet") private var quietDark = true

    var body: some View {
        let id = ThemeID.from(themeRaw)
        let theme = id.theme(dark: id == .crayon ? crayonDark : quietDark)
        ZStack {
            theme.background
                .ignoresSafeArea()
            screen
        }
        .environment(\.theme, theme)
        .sheet(item: $panel) { panel in
            sheetContent(panel)
                .environment(\.theme, theme)
                .preferredColorScheme(theme.colorScheme)
                // Settings and the transition picker are full-height tasks. Lifetime stats open from
                // Settings; nerd mode shows the live details and session log on Now Playing.
                .presentationDetents([.large])
                .presentationDragIndicator(.hidden)
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
        .preferredColorScheme(theme.colorScheme)
    }

    @ViewBuilder
    private var screen: some View {
        if spotifyManager.isAuthenticated {
            NowPlayingScreen(
                bleManager: bleManager,
                spotifyManager: spotifyManager,
                onOpen: { panel = $0 }
            )
        } else {
            SignedOutScreen(
                bleManager: bleManager,
                spotifyManager: spotifyManager,
                onOpen: { panel = $0 }
            )
        }
    }

    @ViewBuilder
    private func sheetContent(_ panel: Panel) -> some View {
        switch panel {
        case .settings:
            SettingsView(spotifyManager: spotifyManager, bleManager: bleManager)
        case .transitions:
            TransitionPickerView(bleManager: bleManager)
        }
    }
}
