import SwiftUI

/// Settings sheet. Every control is wired to something that already exists in the app:
/// brightness (BLE), the debug toggle, cache count/clear (BLE), Spotify sign-in/out, and the
/// Client ID override. The theme picker is the only new setting and is purely visual.
struct SettingsView: View {
    @ObservedObject var spotifyManager: SpotifyManager
    @ObservedObject var bleManager: BLEManager

    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @AppStorage("showDebugInfo") private var showDebugInfo = false
    @AppStorage(ThemeID.storageKey) private var themeRaw = ThemeID.fallback.rawValue
    @State private var showTransitions = false
    @State private var showLifetimeStats = false
    @ScaledMetric(relativeTo: .body) private var chevronSize: CGFloat = 14

    @State private var clientIDOverride = ""
    @State private var brightnessValue: Double = 200
    /// Status light (the board's inner LED) as 0...100 % of its safe maximum.
    @State private var statusLightPercent: Double = 100
    @State private var isClearingCache = false
    @State private var isSigningIn = false
    @State private var isSigningOut = false
    @State private var overrideNote: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                SheetHeader(title: theme.id.text(.settings)) { dismiss() }
                brightnessRow
                statusLightRow
                statsToggleRow
                ThemedDivider()
                ThemePicker(selection: $themeRaw)
                ThemedDivider()
                VStack(alignment: .leading, spacing: 4) {
                    transitionsRow
                    lifetimeStatsRow
                }
                ThemedDivider()
                cacheRows
                ThemedDivider()
                spotifyRows
                ThemedDivider()
                clientIDRows
            }
            .padding(.horizontal, theme.margin + 4)
            .padding(.bottom, 32)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(theme.background.ignoresSafeArea())
        .onAppear {
            clientIDOverride = spotifyManager.storedClientIdOverride
            brightnessValue = Double(bleManager.brightness)
            statusLightPercent = (Double(bleManager.statusLedLevel) / 255 * 100).rounded()
        }
    }

    // MARK: Display

    /// The board's inner status LED (BLE_PROTOCOL 1.13, ffe6). 100 % = the board's own safe maximum
    /// (~47 % of the LED's full power), so this can never make it blinding; 0 % = always off.
    private var statusLightRow: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Status light")
                    .themeText(.row)
                    .foregroundStyle(theme.ink)
                Spacer()
                Text(statusLightPercent < 1 ? "Off" : "\(Int(statusLightPercent))%")
                    .themeText(.rowValue)
                    .foregroundStyle(theme.inkSoft)
            }
            .accessibilityHidden(true)
            Slider(value: $statusLightPercent, in: 0...100, step: 5)
                .tint(theme.sliderTint)
                .accessibilityLabel("Status light")
                .accessibilityValue(statusLightPercent < 1 ? "Off" : "\(Int(statusLightPercent)) percent")
                .onChange(of: statusLightPercent) { newValue in
                    let level = (min(100.0, max(0.0, newValue)) / 100 * 255).rounded()
                    bleManager.setStatusLedLevel(UInt8(level))
                }
            if bleManager.isConnected && !bleManager.boardSupportsStatusLed {
                Text("This display's firmware has no status-light control yet. Flash the latest firmware.")
                    .themeText(.footnote)
                    .foregroundStyle(theme.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var brightnessRow: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(theme.id.text(.brightness))
                    .themeText(.row)
                    .foregroundStyle(theme.ink)
                Spacer()
                Text("\(Int(brightnessValue))")
                    .themeText(.rowValue)
                    .foregroundStyle(theme.inkSoft)
            }
            .accessibilityHidden(true)
            Slider(value: $brightnessValue, in: 0...255, step: 1)
                .tint(theme.sliderTint)
                .accessibilityLabel(theme.id.text(.brightness))
                .accessibilityValue("\(Int(brightnessValue)) of 255")
                .onChange(of: brightnessValue) { newValue in
                    let clamped = min(255.0, max(0.0, newValue))
                    bleManager.setBrightness(UInt8(clamped))
                }
        }
    }

    private var statsToggleRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(isOn: $showDebugInfo) {
                Text(theme.id.text(.showStats))
                    .themeText(.row)
                    .foregroundStyle(theme.ink)
            }
            .toggleStyle(ThemedToggleStyle())
            Text(theme.id.text(.showStatsHint))
                .themeText(.footnote)
                .foregroundStyle(theme.inkSoft)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Opens the transition picker (which transitions the display may use, with live examples).
    private var transitionsRow: some View {
        navRow(title: theme.id.text(.transitionsRow)) {
            showTransitions = true
        }
        .sheet(isPresented: $showTransitions) {
            TransitionPickerView(bleManager: bleManager)
                .environment(\.theme, theme)
                .preferredColorScheme(theme.colorScheme)
        }
    }

    /// Opens the general transfer stats (totals, cache counts, averages, recent transfers).
    private var lifetimeStatsRow: some View {
        navRow(title: theme.id.text(.lifetimeStats)) {
            showLifetimeStats = true
        }
        .sheet(isPresented: $showLifetimeStats) {
            LifetimeStatsView(bleManager: bleManager, spotifyManager: spotifyManager)
                .environment(\.theme, theme)
                .preferredColorScheme(theme.colorScheme)
        }
    }

    /// A row that opens another page: title, then "Choose" and a chevron.
    private func navRow(title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 8) {
                Text(title)
                    .themeText(.row)
                    .foregroundStyle(theme.ink)
                Spacer(minLength: 8)
                Text(theme.id.text(.choose))
                    .themeText(.rowValue)
                    .foregroundStyle(theme.inkSoft)
                    .accessibilityHidden(true)
                GlyphIcon(glyph: .chevronLeft, color: theme.inkSoft, size: chevronSize)
                    .rotationEffect(.degrees(180))
                    .accessibilityHidden(true)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityHint("Opens a new page")
    }

    private var cacheCountText: String {
        guard bleManager.isConnected else { return theme.id.text(.notConnected) }
        if let count = bleManager.sdCacheEntryCount { return "\(count)" }
        if bleManager.sdCacheCountLoading { return theme.id.text(.counting) }
        return "\u{2014}"
    }

    private var cacheRows: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(theme.id.text(.onTheDisplay))
                    .themeText(.row)
                    .foregroundStyle(theme.ink)
                Spacer()
                Text(cacheCountText)
                    .themeText(.rowValue)
                    .foregroundStyle(theme.inkSoft)
            }
            .frame(minHeight: 44)
            .accessibilityElement(children: .combine)

            Button {
                isClearingCache = true
            } label: {
                Text(theme.id.text(.emptyCache))
                    .themeText(.row)
                    .foregroundStyle(bleManager.isConnected ? theme.destructive : theme.inkFaint)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!bleManager.isConnected)
            .alert(theme.id.text(.emptyCacheConfirm), isPresented: $isClearingCache) {
                Button("Cancel", role: .cancel) {}
                Button("Clear", role: .destructive) {
                    Task {
                        try? await bleManager.clearDisplayCache()
                    }
                }
            } message: {
                Text("This removes all cached .bin files on the display SD card.")
            }
        }
    }

    // MARK: Spotify

    private var spotifyRows: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                StateMarker(
                    filled: spotifyManager.isAuthenticated,
                    fillColor: theme.spotify,
                    ringColor: theme.ringOff,
                    size: 12
                )
                Text(theme.id.text(spotifyManager.isAuthenticated ? .spotifySignedIn : .spotifySignedOut))
                    .themeText(.row)
                    .foregroundStyle(theme.ink)
            }
            .accessibilityElement(children: .combine)

            Button {
                isSigningIn = true
                Task {
                    await spotifyManager.signInWithSpotify()
                    isSigningIn = false
                }
            } label: {
                HStack(spacing: 10) {
                    Text(theme.id.text(spotifyManager.isAuthenticated ? .signInAgain : .connectSpotify))
                        .themeText(.row)
                        .foregroundStyle(theme.ink)
                    if isSigningIn {
                        ProgressView().tint(theme.ink)
                    }
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isSigningIn)

            if spotifyManager.isAuthenticated {
                Button {
                    isSigningOut = true
                } label: {
                    Text(theme.id.text(.signOut))
                        .themeText(.row)
                        .foregroundStyle(theme.inkSoft)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .alert("Sign out of Spotify?", isPresented: $isSigningOut) {
                    Button("Cancel", role: .cancel) {}
                    Button("Sign Out", role: .destructive) {
                        spotifyManager.signOut()
                    }
                } message: {
                    Text("You'll need to sign in again to control playback.")
                }
            }

            if let error = spotifyManager.lastError, !error.isEmpty {
                Text(error)
                    .themeText(.footnote)
                    .foregroundStyle(theme.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Client ID

    private var clientIDRows: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(theme.id.text(.clientID))
                .themeText(.row)
                .foregroundStyle(theme.ink)
                .accessibilityAddTraits(.isHeader)
            Text("Active: \(spotifyManager.clientIdSourceDescription). The default comes from SpotifyClientID in Info.plist; an override here wins.")
                .themeText(.footnote)
                .foregroundStyle(theme.inkSoft)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 6) {
                TextField(
                    "",
                    text: $clientIDOverride,
                    prompt: Text("Client ID override (optional)").foregroundColor(theme.inkFaint)
                )
                .themeText(.rowValue)
                .foregroundStyle(theme.ink)
                // Not a username: tagging it so made iOS offer saved passwords for this field.
                .keyboardType(.asciiCapable)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .frame(minHeight: 44)
                .accessibilityLabel("Client ID override")
                ThemedDivider()
            }

            HStack(spacing: 24) {
                textButton("Save override") {
                    spotifyManager.saveClientId(clientIDOverride)
                    overrideNote = clientIDOverride.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? "Using Info.plist"
                        : "Saved"
                }
                textButton("Clear override") {
                    clientIDOverride = ""
                    spotifyManager.saveClientId("")
                    overrideNote = "Using Info.plist"
                }
            }
            if let overrideNote {
                Text(overrideNote)
                    .themeText(.footnote)
                    .foregroundStyle(theme.inkSoft)
            }

            Text("Add the redirect URI spotifydisplay://callback in the Spotify Developer Dashboard.")
                .themeText(.footnote)
                .foregroundStyle(theme.inkSoft)
                .fixedSize(horizontal: false, vertical: true)
            if let url = URL(string: "https://developer.spotify.com/dashboard") {
                Link(destination: url) {
                    Text("Open the Spotify Dashboard")
                        .underline()
                        .themeText(.rowValue)
                        .foregroundStyle(theme.ink)
                        .frame(minHeight: 44)
                }
            }
        }
    }

    private func textButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .themeText(.rowValue)
                .foregroundStyle(theme.ink)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Theme picker

/// Chooses a theme (not a light/dark mode): each option is set in its own typeface, and the
/// selection is shown by a filled dot vs hollow ring as well as by VoiceOver's "selected".
struct ThemePicker: View {
    @Binding var selection: String
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(theme.id.text(.themeTitle))
                .themeText(.row)
                .foregroundStyle(theme.ink)
                .accessibilityAddTraits(.isHeader)
                .padding(.bottom, 6)
            ForEach(ThemeID.allCases) { option in
                optionRow(option)
            }
        }
    }

    private func optionRow(_ option: ThemeID) -> some View {
        let isSelected = ThemeID.from(selection) == option
        return Button {
            selection = option.rawValue
        } label: {
            HStack(spacing: 12) {
                StateMarker(filled: isSelected, fillColor: theme.ink, ringColor: theme.ringOff, size: 14)
                VStack(alignment: .leading, spacing: 1) {
                    Text(option.displayName)
                        .font(Self.previewFont(option))
                        .foregroundStyle(theme.ink)
                    Text(option.blurb)
                        .themeText(.footnote)
                        .foregroundStyle(theme.inkSoft)
                }
                Spacer(minLength: 0)
            }
            .frame(minHeight: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(option.displayName) theme, \(option.blurb)")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : [.isButton])
    }

    /// Each option's name is set in that theme's own face so the choice previews itself.
    private static func previewFont(_ option: ThemeID) -> Font {
        switch option {
        case .crayon: return .custom("ChalkboardSE-Bold", size: 19, relativeTo: .body)
        case .quiet: return .system(.body).weight(.semibold)
        case .serif: return .custom("TimesNewRomanPSMT", size: 20, relativeTo: .body)
        }
    }
}

// MARK: - Toggle

/// A themed switch: filled track = on, outlined track = off (shape, not just colour), knob
/// position as a third cue. VoiceOver sees a standard switch via `accessibilityRepresentation`.
struct ThemedToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        ThemedToggleBody(configuration: configuration)
    }
}

struct ThemedToggleBody: View {
    let configuration: ToggleStyleConfiguration
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button {
            if reduceMotion {
                configuration.isOn.toggle()
            } else {
                withAnimation(.easeOut(duration: 0.15)) {
                    configuration.isOn.toggle()
                }
            }
        } label: {
            HStack(spacing: 12) {
                configuration.label
                Spacer(minLength: 12)
                track
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) {
                configuration.label
            }
        }
    }

    private var track: some View {
        let isOn = configuration.isOn
        let shape = WobbleRoundedRect(cornerRadius: 15, amplitude: theme.wobble * 0.7, seed: 31)
        return ZStack(alignment: isOn ? .trailing : .leading) {
            if isOn {
                shape.fill(theme.toggleOnFill)
            } else {
                shape.stroke(theme.toggleOff, lineWidth: 2)
            }
            Circle()
                .fill(isOn ? theme.toggleOnKnob : theme.toggleOff)
                .frame(width: isOn ? 22 : 20, height: isOn ? 22 : 20)
                .padding(isOn ? 4 : 5)
        }
        .frame(width: 52, height: 30)
    }
}
