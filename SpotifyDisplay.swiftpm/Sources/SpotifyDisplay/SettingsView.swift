import SwiftUI

/// Settings sheet. Every control is wired to something that already exists in the app:
/// brightness (BLE), cache count/clear (BLE), Spotify sign-in/out, and the
/// Client ID override. The theme picker is the only new setting and is purely visual.
struct SettingsView: View {
    @ObservedObject var spotifyManager: SpotifyManager
    @ObservedObject var bleManager: BLEManager

    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @AppStorage(ThemeID.storageKey) private var themeRaw = ThemeID.fallback.rawValue
    @AppStorage("uiDark.crayon") private var crayonDark = false
    @AppStorage("uiDark.quiet") private var quietDark = true
    /// Switched-off transitions, for the "49/49" count on the Transitions row.
    @AppStorage(TransitionPrefs.storageKey) private var disabledTransitionsRaw = ""
    /// Nerd mode is available: the main screen shows its terminal icon.
    @AppStorage(NerdMode.enabledKey) private var nerdEnabled = false
    /// Nerd layout currently on (the terminal icon's state); switched off with the feature.
    @AppStorage(NerdMode.layoutKey) private var nerdLayout = false
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
                // What is on the keychain, and emptying it.
                cacheRows
                ThemedDivider()
                // The display itself: how it looks and draws.
                brightnessRow
                statusLightRow
                transitionsRow
                ThemedDivider()
                ThemePicker(selection: $themeRaw, crayonDark: $crayonDark, quietDark: $quietDark)
                ThemedDivider()
                // Numbers: nerd mode (live, on the main screen) and the all-time totals.
                nerdModeRow
                lifetimeStatsRow
                ThemedDivider()
                spotifyRows
                ThemedDivider()
                clientIDRows
                // Which cloud build this is (the GitHub Actions run number), to match reports to builds.
                Text("app build \(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?")")
                    .themeText(.footnote)
                    .foregroundStyle(theme.inkFaint)
                    .frame(maxWidth: .infinity, alignment: .center)
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

    /// Turns nerd mode on as a feature: the terminal icon appears at the top of the main screen.
    private var nerdModeRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(isOn: $nerdEnabled) {
                Text(theme.id.text(.showStats))
                    .themeText(.row)
                    .foregroundStyle(theme.ink)
            }
            .toggleStyle(ThemedToggleStyle())
            .onChange(of: nerdEnabled) { on in
                if !on { nerdLayout = false }
            }
            Text(theme.id.text(.showStatsHint))
                .themeText(.footnote)
                .foregroundStyle(theme.inkSoft)
                .fixedSize(horizontal: false, vertical: true)
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

    /// Opens the transition picker (which transitions the display may use, with live examples).
    private var transitionsRow: some View {
        navRow(
            title: theme.id.text(.transitionsRow),
            value: "\(TransitionPrefs.enabledCount(disabledRaw: disabledTransitionsRaw))/\(TransitionCatalog.all.count)",
            valueLabel: "\(TransitionPrefs.enabledCount(disabledRaw: disabledTransitionsRaw)) of \(TransitionCatalog.all.count) on"
        ) {
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

    /// A row that opens another page: title, an optional value (like "49/49") and a chevron.
    private func navRow(
        title: String,
        value: String? = nil,
        valueLabel: String? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 8) {
                Text(title)
                    .themeText(.row)
                    .foregroundStyle(theme.ink)
                Spacer(minLength: 8)
                if let value {
                    Text(value)
                        .themeText(.rowValue)
                        .monospacedDigit()
                        .foregroundStyle(theme.inkSoft)
                        .accessibilityHidden(true)
                }
                GlyphIcon(glyph: .chevronLeft, color: theme.inkSoft, size: chevronSize)
                    .rotationEffect(.degrees(180))
                    .accessibilityHidden(true)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(valueLabel ?? value ?? "")
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

/// Chooses a theme and, per theme, day or night. Each option previews itself: a small card on that
/// theme's own page colour, its name in its own face (Crayon's letters in its crayon colours) and a
/// row of its colours. Selection is a filled dot vs hollow ring as well as VoiceOver's "selected".
struct ThemePicker: View {
    @Binding var selection: String
    @Binding var crayonDark: Bool
    @Binding var quietDark: Bool
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(theme.id.text(.themeTitle))
                .themeText(.row)
                .foregroundStyle(theme.ink)
                .accessibilityAddTraits(.isHeader)
            ForEach(ThemeID.allCases) { option in
                optionRow(option)
            }
        }
    }

    private func darkBinding(_ option: ThemeID) -> Binding<Bool> {
        option == .crayon ? $crayonDark : $quietDark
    }

    private func optionRow(_ option: ThemeID) -> some View {
        let isSelected = ThemeID.from(selection) == option
        let dark = darkBinding(option)
        let look = option.theme(dark: dark.wrappedValue)
        return HStack(spacing: 10) {
            Button {
                selection = option.rawValue
            } label: {
                HStack(spacing: 12) {
                    StateMarker(filled: isSelected, fillColor: theme.ink, ringColor: theme.ringOff, size: 14)
                    preview(option, look: look)
                    Spacer(minLength: 0)
                }
                .frame(minHeight: 64)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(option.displayName) theme, \(option.blurb)")
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : [.isButton])
            DayNightSwitch(isDark: dark, themeName: option.displayName)
        }
    }

    /// The theme drawn on its own page colour, so its colours read as they will in the app.
    private func preview(_ option: ThemeID, look: Theme) -> some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        let isDark = look.colorScheme == .dark
        return VStack(alignment: .leading, spacing: 6) {
            name(option, look: look)
            HStack(spacing: 5) {
                ForEach(Array(option.swatch(dark: isDark).enumerated()), id: \.offset) { _, color in
                    Circle()
                        .fill(color)
                        .frame(width: 10, height: 10)
                        .overlay(Circle().stroke(look.ink.opacity(0.15), lineWidth: 1))
                }
                Text(option.blurb)
                    .font(.caption2)
                    .foregroundStyle(look.inkSoft)
                    .lineLimit(1)
                    .padding(.leading, 4)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(shape.fill(look.background))
        .overlay(shape.stroke(theme.ringOff.opacity(0.5), lineWidth: 1))
    }

    @ViewBuilder
    private func name(_ option: ThemeID, look: Theme) -> some View {
        switch option {
        case .crayon:
            // One crayon per letter. Day uses the darker crayons so every letter keeps 3:1 on white.
            let hexes: [UInt32] = look.colorScheme == .dark
                ? [0xFFA040, 0x64B5F6, 0xFF7A70, 0xCE93D8, 0x66BB6A, 0xF5D04A]
                : [0xE65100, 0x1565C0, 0xC62828, 0x6A1B9A, 0x2E7D32, 0xB26A00]
            let colors = hexes.map { Color(hex: $0) }
            HStack(spacing: 0) {
                ForEach(Array("Crayon".enumerated()), id: \.offset) { i, letter in
                    Text(String(letter))
                        .font(Self.previewFont(.crayon))
                        .foregroundStyle(colors[i % colors.count])
                }
            }
        case .quiet:
            HStack(spacing: 6) {
                Text(option.displayName)
                    .font(Self.previewFont(.quiet))
                    .foregroundStyle(look.ink)
                // Quiet's only colour lives in its two status dots.
                Circle().fill(look.spotify).frame(width: 7, height: 7)
                Circle().fill(look.display).frame(width: 7, height: 7)
            }
        }
    }

    /// Each option's name is set in that theme's own face so the choice previews itself.
    private static func previewFont(_ option: ThemeID) -> Font {
        switch option {
        case .crayon: return .custom("ChalkboardSE-Bold", size: 19, relativeTo: .body)
        case .quiet: return .system(.body).weight(.semibold)
        }
    }
}

/// Day / night for one theme: a sun and a moon, the chosen one filled. 44 pt targets.
struct DayNightSwitch: View {
    @Binding var isDark: Bool
    let themeName: String
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 0) {
            segment(dark: false, symbol: "sun.max.fill", label: "Day")
            segment(dark: true, symbol: "moon.fill", label: "Night")
        }
        .padding(2)
        .background(Capsule().stroke(theme.ringOff.opacity(0.6), lineWidth: 1))
    }

    private func segment(dark: Bool, symbol: String, label: String) -> some View {
        let on = isDark == dark
        return Button {
            withAnimation(.easeOut(duration: 0.15)) { isDark = dark }
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(on ? theme.background : theme.inkSoft)
                .frame(width: 40, height: 32)
                .background(Capsule().fill(on ? theme.ink : Color.clear))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(themeName) \(label)")
        .accessibilityAddTraits(on ? [.isButton, .isSelected] : [.isButton])
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
