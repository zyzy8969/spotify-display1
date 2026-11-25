import SwiftUI

/// Settings sheet, laid out for someone who just bought the keychain (owner, 2026-11-23: "more
/// consumer friendly"): a status line first (the app's job is glance-and-confirm), then plain
/// sections in the order people reach for them: the keychain itself, the look, Spotify. Builder
/// tools (nerd mode, lifetime stats, clearing the card, the Client ID override, the build number)
/// sit under a collapsed Advanced section. Sections are separated by space and a heading only: no
/// cards or panels (DESIGN.md, Only-the-Cover-Floats).
struct SettingsView: View {
    @ObservedObject var spotifyManager: SpotifyManager
    @ObservedObject var bleManager: BLEManager

    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @AppStorage(ThemeID.storageKey) private var themeRaw = ThemeID.fallback.rawValue
    @AppStorage("uiDark.crayon") private var crayonDark = false
    @AppStorage("uiDark.quiet") private var quietDark = true
    @AppStorage("uiDark.keyring") private var keyringDark = false
    /// Switched-off transitions, for the "49/49" count on the Transitions row.
    @AppStorage(TransitionPrefs.storageKey) private var disabledTransitionsRaw = ""
    /// Nerd mode is available: the main screen shows its terminal icon.
    @AppStorage(NerdMode.enabledKey) private var nerdEnabled = false
    /// Nerd layout currently on (the terminal icon's state); switched off with the feature.
    @AppStorage(NerdMode.layoutKey) private var nerdLayout = false
    /// Show a random starred photo when the keychain connects with nothing playing.
    @AppStorage(PhotoLibrary.startupPictureKey) private var startupPicture = false
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
    /// The Advanced section is open (closed every time Settings opens).
    @State private var showAdvanced = false
    /// The LED-only colour wheel sheet that is open, if any.
    @State private var wheelTarget: WheelTarget?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                SheetHeader(title: theme.id.text(.settings)) { dismiss() }
                keychainStatus
                    .padding(.top, 4)

                section(theme.id.text(.sectionKeychain)) {
                    brightnessRow
                    statusLightRow
                    transitionsRow
                    startupPictureRow
                }
                section(theme.id.text(.themeTitle)) {
                    ThemePicker(selection: $themeRaw, crayonDark: $crayonDark, quietDark: $quietDark,
                                keyringDark: $keyringDark, showsTitle: false)
                }
                section(theme.id.text(.sectionSpotify)) {
                    spotifyRows
                }
                advancedSection
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

    // MARK: Layout

    /// One group of settings: a heading, then its rows. More room above the heading than below it,
    /// so each heading reads as the start of its group.
    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(title)
                .themeText(.sectionTitle)
                .foregroundStyle(theme.ink)
                .accessibilityAddTraits(.isHeader)
            content()
        }
        .padding(.top, 36)
    }

    /// First line of Settings: is the keychain there, and how many covers it holds. The dot is the
    /// same filled / hollow mark as the main screen's header, so it reads without colour.
    private var keychainStatus: some View {
        HStack(spacing: 10) {
            StateMarker(filled: bleManager.isConnected, fillColor: theme.display, ringColor: theme.ringOff, size: 12)
            Text(theme.id.text(bleManager.isConnected ? .keychainConnected : .lookingForDisplay))
                .themeText(.row)
                .foregroundStyle(theme.ink)
            Spacer(minLength: 8)
            if bleManager.isConnected, let count = bleManager.sdCacheEntryCount {
                Text(theme.id.countText(count))
                    .themeText(.rowValue)
                    .monospacedDigit()
                    .foregroundStyle(theme.inkSoft)
            }
        }
        .frame(minHeight: 44)
        .accessibilityElement(children: .combine)
    }

    /// Builder tools, closed by default so a new owner sees only the everyday settings.
    private var advancedSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            Button {
                withAnimation(.easeOut(duration: 0.2)) { showAdvanced.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Text(theme.id.text(.sectionAdvanced))
                        .themeText(.sectionTitle)
                        .foregroundStyle(theme.ink)
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(theme.inkSoft)
                        .rotationEffect(.degrees(showAdvanced ? 0 : -90))
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(.isHeader)
            .accessibilityValue(showAdvanced ? "Open" : "Closed")
            .accessibilityHint(showAdvanced ? "Hides the advanced settings" : "Shows nerd mode, stats, clearing the keychain and the Spotify Client ID")

            if showAdvanced {
                VStack(alignment: .leading, spacing: 22) {
                    nerdModeRow
                    lifetimeStatsRow
                    cacheRows
                    ThemedDivider()
                    clientIDRows
                    // Which cloud build this is (the GitHub Actions run number), to match reports to builds.
                    Text("app build \(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?")")
                        .themeText(.footnote)
                        .foregroundStyle(theme.inkFaint)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
                .transition(.opacity)
            }
        }
        .padding(.top, 36)
    }

    // MARK: Display

    /// The board's inner status LED (BLE_PROTOCOL 1.13, ffe6). 100 % = the board's own safe maximum
    /// (~59 % of the LED's full power), so this can never make it blinding; 0 % = always off.
    private var statusLightRow: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(theme.id.text(.statusLight))
                    .themeText(.row)
                    .foregroundStyle(theme.ink)
                Spacer()
                Text(statusLightPercent < 1 ? "Off" : "\(Int(statusLightPercent))%")
                    .themeText(.rowValue)
                    .foregroundStyle(theme.inkSoft)
            }
            .accessibilityHidden(true)
            Slider(value: $statusLightPercent, in: 0...100, step: 5) {
                Text(theme.id.text(.statusLight))
            } minimumValueLabel: {
                sliderEnd("lightbulb.slash")
            } maximumValueLabel: {
                sliderEnd("lightbulb.fill")
            }
                .tint(theme.sliderTint)
                .accessibilityLabel(theme.id.text(.statusLight))
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
            lightStylePicker
            if bleManager.lightStyle == .consumer {
                loadingColourPicker
                songLightPicker
                    .sheet(item: $wheelTarget) { target in
                        wheelSheet(target)
                            .environment(\.theme, theme)
                    }
            }
            if bleManager.isConnected && bleManager.boardSupportsStatusLed && !bleManager.boardSupportsLights {
                Text("This display's firmware only knows the developer lights. Flash the latest firmware for the consumer lights and loading colour.")
                    .themeText(.footnote)
                    .foregroundStyle(theme.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Consumer (calm, default) or Developer (per-song colours) lights (BLE_PROTOCOL 1.19).
    private var lightStylePicker: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 0) {
                ForEach(LightStyle.allCases) { style in
                    let selected = bleManager.lightStyle == style
                    Button { bleManager.setLightStyle(style) } label: {
                        HStack(spacing: 6) {
                            StateMarker(filled: selected, fillColor: theme.display, ringColor: theme.ringOff, size: 9)
                            Text(style.title)
                                .themeText(.rowValue)
                                .foregroundStyle(selected ? theme.ink : theme.inkSoft)
                        }
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(style.title) lights")
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            Text(bleManager.lightStyle == .consumer
                 ? "Breathes white while it looks for your phone and shows a rainbow when it finds it. Pulses your loading colour while a cover is on its way, then green once it's on. Blinks amber if it loses your phone."
                 : "A colour per song: blue from the card, orange sent new, blue and orange flashes saved ahead from your queue, green drawn, red an error.")
                .themeText(.footnote)
                .foregroundStyle(theme.inkSoft)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The consumer loading pulse's colour: swatches with their names, so the choice never depends on
    /// telling colours apart.
    private var loadingColourPicker: some View {
        loadingColourGrid
            // While the picker is on screen the board keeps pulsing the colour (BLE_PROTOCOL 1.21).
            .onAppear { bleManager.setLightPreview(true) }
            .onDisappear { bleManager.setLightPreview(false) }
    }

    private var loadingColourGrid: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Loading colour")
                .themeText(.rowValue)
                .foregroundStyle(theme.ink)
            // Owner, 2026-11-24: ROYGBIV + pink + white, then Rainbow / Wheel / Gradient: a 4x3 grid (was 13 named swatches).
            LazyVGrid(columns: swatchColumns, spacing: 6) {
                ForEach(LightPalette.swatches, id: \.hex) { swatch in
                    let selected = bleManager.loadingColour == .custom && bleManager.customLoadingHex == swatch.hex
                    Button { bleManager.setCustomLoadingColour(swatch.hex) } label: {
                        swatchCell(title: swatch.name, selected: selected) {
                            PulsingFill(pulsing: selected) { Circle().fill(Color(hex: swatch.hex)) }
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(swatch.name) loading colour")
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
                let rainbowSelected = bleManager.loadingColour == .rainbow
                Button { bleManager.setLoadingColour(.rainbow) } label: {
                    swatchCell(title: "Rainbow", selected: rainbowSelected) {
                        LoadingSwatch(colour: .rainbow, pulsing: rainbowSelected)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Rainbow loading colour")
                .accessibilityAddTraits(rainbowSelected ? .isSelected : [])
                // BLE 1.23: any colour from the colour wheel.
                wheelCell(hex: bleManager.customLoadingHex,
                          selected: bleManager.loadingColour == .custom
                              && !LightPalette.isSwatch(bleManager.customLoadingHex),
                          label: "Custom loading colour", target: .loading)
                // BLE 1.24: fade through 1-6 colours.
                let gradientSelected = bleManager.loadingColour == .gradient
                Button { bleManager.setGradient(bleManager.gradientHexes) } label: {
                    swatchCell(title: "Gradient", selected: gradientSelected) {
                        PulsingFill(pulsing: gradientSelected) {
                            Circle().fill(AngularGradient(
                                colors: (bleManager.gradientHexes + [bleManager.gradientHexes[0]]).map { Color(hex: $0) },
                                center: .center))
                        }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Gradient loading colour")
                .accessibilityAddTraits(gradientSelected ? .isSelected : [])
            }
            if bleManager.loadingColour == .gradient {
                gradientEditor
            }
        }
    }

    private var swatchColumns: [GridItem] { Array(repeating: GridItem(.flexible(), spacing: 6), count: 4) }

    /// BLE 1.24: the gradient's colours, each a colour well; − drops the last, + adds one (up to 6).
    private var gradientEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Gradient colours (\(bleManager.gradientHexes.count) of \(LoadingColour.gradientMax))")
                .themeText(.footnote)
                .foregroundStyle(theme.inkSoft)
            HStack(spacing: 10) {
                ForEach(bleManager.gradientHexes.indices, id: \.self) { index in
                    Button { wheelTarget = .gradient(index) } label: {
                        Circle()
                            .fill(Color(hex: bleManager.gradientHexes[index]))
                            .overlay(Circle().stroke(theme.ringOff, lineWidth: 1))
                            .frame(width: 28, height: 28)
                            .frame(width: 36, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Gradient colour \(index + 1)")
                }
                Spacer(minLength: 0)
                Button {
                    bleManager.setGradient(Array(bleManager.gradientHexes.dropLast()))
                } label: {
                    Image(systemName: "minus.circle")
                        .font(.title3)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .foregroundStyle(bleManager.gradientHexes.count > 1 ? theme.ink : theme.inkFaint)
                .disabled(bleManager.gradientHexes.count <= 1)
                .accessibilityLabel("Remove last gradient colour")
                Button {
                    // A new stop starts as the next palette colour after the last one, so it differs.
                    let last = bleManager.gradientHexes.last ?? 0xFF0000
                    let i = LightPalette.swatches.firstIndex { $0.hex == last } ?? -1
                    let next = LightPalette.swatches[(i + 1) % LightPalette.swatches.count].hex
                    bleManager.setGradient(bleManager.gradientHexes + [next])
                } label: {
                    Image(systemName: "plus.circle")
                        .font(.title3)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .foregroundStyle(bleManager.gradientHexes.count < LoadingColour.gradientMax ? theme.ink : theme.inkFaint)
                .disabled(bleManager.gradientHexes.count >= LoadingColour.gradientMax)
                .accessibilityLabel("Add a gradient colour")
            }
            Text("The light fades from each colour to the next while a cover loads, 1 s per colour.")
                .themeText(.footnote)
                .foregroundStyle(theme.inkSoft)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Which colour the LED-only wheel sheet is editing.
    enum WheelTarget: Identifiable, Equatable {
        case loading, song, gradient(Int)
        var id: String {
            switch self {
            case .loading: return "loading"
            case .song: return "song"
            case .gradient(let i): return "gradient\(i)"
            }
        }
    }

    /// The LED-only colour wheel (`LEDColourWheelSheet`) for one target.
    @ViewBuilder
    private func wheelSheet(_ target: WheelTarget) -> some View {
        switch target {
        case .loading:
            LEDColourWheelSheet(title: "Loading colour", initialHex: bleManager.customLoadingHex) {
                bleManager.setCustomLoadingColour($0)
            }
        case .song:
            LEDColourWheelSheet(title: "Song colour", initialHex: bleManager.songLightHex) {
                bleManager.setSongLightColour($0)
            }
        case .gradient(let index):
            LEDColourWheelSheet(title: "Gradient colour \(index + 1)",
                                initialHex: index < bleManager.gradientHexes.count ? bleManager.gradientHexes[index] : 0xFF0000) { hex in
                var hexes = bleManager.gradientHexes
                guard index < hexes.count else { return }
                hexes[index] = hex
                bleManager.setGradient(hexes)
            }
        }
    }

    /// BLE 1.23: what the light does while a song is on the keychain (after the loading pulse and green):
    /// off, a slow rainbow, one colour you pick, or a colour that matches the cover.
    private var songLightPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("During a song")
                .themeText(.rowValue)
                .foregroundStyle(theme.ink)
            HStack(spacing: 0) {
                ForEach(SongLight.allCases) { mode in
                    let selected = bleManager.songLight == mode
                    Button { bleManager.setSongLight(mode) } label: {
                        HStack(spacing: 6) {
                            StateMarker(filled: selected, fillColor: theme.display, ringColor: theme.ringOff, size: 9)
                            Text(mode.title)
                                .themeText(.rowValue)
                                .foregroundStyle(selected ? theme.ink : theme.inkSoft)
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                        }
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(mode.title) during a song")
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            if bleManager.songLight == .colour {
                LazyVGrid(columns: swatchColumns, spacing: 6) {
                    ForEach(LightPalette.swatches, id: \.hex) { swatch in
                        let selected = swatch.hex == bleManager.songLightHex
                        Button { bleManager.setSongLightColour(swatch.hex) } label: {
                            swatchCell(title: swatch.name, selected: selected) {
                                Circle().fill(Color(hex: swatch.hex))
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(swatch.name) song colour")
                        .accessibilityAddTraits(selected ? .isSelected : [])
                    }
                    wheelCell(hex: bleManager.songLightHex,
                              selected: !LightPalette.isSwatch(bleManager.songLightHex),
                              label: "Custom song colour", target: .song)
                }
            }
            if bleManager.songLight == .album {
                HStack(spacing: 8) {
                    Circle()
                        .fill(Color(hex: bleManager.albumLightHex))
                        .overlay(Circle().stroke(theme.ringOff, lineWidth: 1))
                        .frame(width: 18, height: 18)
                        .accessibilityHidden(true)
                    Text("Now: picked from the cover on the keychain")
                        .themeText(.footnote)
                        .foregroundStyle(theme.inkSoft)
                }
            }
            Text(songLightHint)
                .themeText(.footnote)
                .foregroundStyle(theme.inkSoft)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var songLightHint: String {
        switch bleManager.songLight {
        case .off: return "The light goes dark once a cover is on."
        case .rainbow: return "A slow rainbow while the song plays. New covers still pulse your loading colour, then green."
        case .colour: return "Stays on your colour while the song plays. New covers still pulse your loading colour, then green."
        case .album: return "Takes the strongest colour from each cover. Black-and-white covers get white."
        }
    }

    /// One round swatch with its name under it; a ring marks the chosen one.
    private func swatchCell<Fill: View>(title: String, selected: Bool, @ViewBuilder fill: () -> Fill) -> some View {
        VStack(spacing: 4) {
            ZStack {
                fill()
                    .overlay(Circle().stroke(theme.ringOff, lineWidth: 1))
                    .frame(width: 26, height: 26)
                if selected {
                    Circle()
                        .stroke(theme.ink, lineWidth: 2)
                        .frame(width: 34, height: 34)
                }
            }
            .frame(width: 36, height: 36)
            Text(title)
                .themeText(.statCaption)
                .foregroundStyle(selected ? theme.ink : theme.inkSoft)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, minHeight: 56)
        .contentShape(Rectangle())
    }

    /// The colour-wheel cell: opens the LED-only wheel (`LEDColourWheelSheet`); picking a colour selects
    /// it. Shows the picked colour once chosen, a little hue wheel otherwise.
    private func wheelCell(hex: UInt32, selected: Bool, label: String, target: WheelTarget) -> some View {
        Button { wheelTarget = target } label: {
            swatchCell(title: "Wheel", selected: selected) {
                if selected {
                    Circle().fill(Color(hex: hex))
                } else {
                    Circle().fill(AngularGradient(colors: [.red, .yellow, .green, .cyan, .blue, .purple, .red],
                                                  center: .center))
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// Start-up picture: a random starred photo (Photos page) when the keychain connects and nothing
    /// is playing. Album art takes over as soon as a song plays.
    private var startupPictureRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(isOn: $startupPicture) {
                Text("Start-up picture")
                    .themeText(.row)
                    .foregroundStyle(theme.ink)
            }
            .toggleStyle(ThemedToggleStyle())
            Text("When the keychain connects and nothing is playing, show one of your starred photos. Star photos on the Photos page.")
                .themeText(.footnote)
                .foregroundStyle(theme.inkSoft)
                .fixedSize(horizontal: false, vertical: true)
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
                Text("\(brightnessPercent)%")
                    .themeText(.rowValue)
                    .monospacedDigit()
                    .foregroundStyle(theme.inkSoft)
            }
            .accessibilityHidden(true)
            // The board takes 0...255; people think in percent.
            Slider(value: $brightnessValue, in: 0...255, step: 1) {
                Text(theme.id.text(.brightness))
            } minimumValueLabel: {
                sliderEnd("sun.min")
            } maximumValueLabel: {
                sliderEnd("sun.max.fill")
            }
                .tint(theme.sliderTint)
                .accessibilityLabel(theme.id.text(.brightness))
                .accessibilityValue("\(brightnessPercent) percent")
                .onChange(of: brightnessValue) { newValue in
                    let clamped = min(255.0, max(0.0, newValue))
                    bleManager.setBrightness(UInt8(clamped))
                }
        }
    }

    private var brightnessPercent: Int { Int((brightnessValue / 255 * 100).rounded()) }

    /// Small SF Symbol at a slider's end (decorative: the slider has its own label).
    private func sliderEnd(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(theme.inkSoft)
            .accessibilityHidden(true)
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
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(theme.id.text(.onTheDisplay))
                    .themeText(.row)
                    .foregroundStyle(theme.ink)
                Spacer()
                Text(cacheCountText)
                    .themeText(.rowValue)
                    .monospacedDigit()
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
                Text("Every cover and photo saved on the keychain's memory card is removed. They are sent again the next time they play.")
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
    @Binding var keyringDark: Bool
    /// Settings shows the picker under its own section heading, so it hides this one.
    var showsTitle = true
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if showsTitle {
                Text(theme.id.text(.themeTitle))
                    .themeText(.row)
                    .foregroundStyle(theme.ink)
                    .accessibilityAddTraits(.isHeader)
            }
            ForEach(ThemeID.allCases) { option in
                optionRow(option)
            }
        }
    }

    private func darkBinding(_ option: ThemeID) -> Binding<Bool> {
        let stored: Binding<Bool>
        switch option {
        case .crayon: stored = $crayonDark
        case .quiet: stored = $quietDark
        case .keyring: stored = $keyringDark
        }
        // Only the theme in use changes how the app looks, so only it fades.
        guard ThemeID.from(selection) == option else { return stored }
        return Binding(
            get: { stored.wrappedValue },
            set: { value in
                guard value != stored.wrappedValue else { return }
                ThemeFade.perform { stored.wrappedValue = value }
            }
        )
    }

    private func optionRow(_ option: ThemeID) -> some View {
        let isSelected = ThemeID.from(selection) == option
        let dark = darkBinding(option)
        let look = option.theme(dark: dark.wrappedValue)
        return HStack(spacing: 10) {
            Button {
                guard !isSelected else { return }
                ThemeFade.perform { selection = option.rawValue }
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
            // Day / night lives only on the main screen's header toggle (owner, 2026-11-24); each
            // preview still shows its theme in the look it was last left in.
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
        case .keyring:
            // A tiny keychain tag: the name in mono caps on the case colour, with its link light.
            HStack(spacing: 6) {
                Text(option.displayName.uppercased())
                    .font(Self.previewFont(.keyring))
                    .tracking(1)
                    .foregroundStyle(look.background)
                Circle().fill(look.display).frame(width: 6, height: 6)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(look.housing?.body ?? look.ink)
            )
        }
    }

    /// Each option's name is set in that theme's own face so the choice previews itself.
    private static func previewFont(_ option: ThemeID) -> Font {
        switch option {
        case .crayon: return .custom("ChalkboardSE-Bold", size: 19, relativeTo: .body)
        case .quiet: return .system(.body).weight(.semibold)
        case .keyring: return .system(.subheadline, design: .monospaced).weight(.semibold)
        }
    }
}

/// One loading-colour swatch. The picked one pulses like the keychain's LED (100% -> 25% -> 100% every
/// 1.6 s; Rainbow also turns, one turn per 0.8 s), so you see the colour while choosing; the board
/// pulses it the whole time the picker is on screen (BLE_PROTOCOL 1.21). Reduce Motion: still.
/// Any swatch fill, pulsing like the keychain's loading light while it is the chosen one.
private struct PulsingFill<Fill: View>: View {
    let pulsing: Bool
    @ViewBuilder let fill: () -> Fill
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(paused: !pulsing || reduceMotion)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let animate = pulsing && !reduceMotion
            fill()
                .opacity(animate ? 1 - 0.75 * (1 - cos(t.truncatingRemainder(dividingBy: 1.6) / 1.6 * 2 * .pi)) / 2 : 1)
        }
    }
}

private struct LoadingSwatch: View {
    let colour: LoadingColour
    let pulsing: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(paused: !pulsing || reduceMotion)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let animate = pulsing && !reduceMotion
            let level = animate ? 1 - 0.75 * (1 - cos(t.truncatingRemainder(dividingBy: 1.6) / 1.6 * 2 * .pi)) / 2 : 1
            Group {
                if colour == .rainbow {
                    Circle()
                        .fill(AngularGradient(colors: [.red, .yellow, .green, .cyan, .blue, .purple, .red],
                                              center: .center))
                        .rotationEffect(.degrees(animate ? t.truncatingRemainder(dividingBy: 0.8) / 0.8 * 360 : 0))
                } else {
                    Circle().fill(Color(hex: colour.hex))
                }
            }
            .opacity(level)
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
