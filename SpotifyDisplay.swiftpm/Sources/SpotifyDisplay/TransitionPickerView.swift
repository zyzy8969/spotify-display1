import SwiftUI

/// Chooses which transitions the board may use. Every row plays a looping example of its effect.
/// The choice is stored as the list of switched-off indices (`TransitionPrefs`) and sent to the
/// board as a bitmask (BLE_PROTOCOL 1.12), so it applies to cache hits and new songs alike.
struct TransitionPickerView: View {
    @ObservedObject var bleManager: BLEManager

    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @AppStorage(TransitionPrefs.storageKey) private var disabledRaw = ""
    /// Custom speeds ("id:percent") and the random-speed switch (BLE_PROTOCOL 1.14).
    @AppStorage(TransitionSpeeds.storageKey) private var speedsRaw = ""
    @AppStorage(TransitionSpeeds.randomKey) private var randomSpeed = TransitionSpeeds.randomDefault
    /// The row whose speed slider is open (only one at a time).
    @State private var speedEditing: Int?
    @State private var showSwipe = false
    @State private var confirmReset = false
    @AppStorage(TransitionSwipeView.previewSpeedsKey) private var swipePreviewSpeedsRaw = "1"

    var body: some View {
        let enabled = TransitionPrefs.enabledCount(disabledRaw: disabledRaw)
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                SheetHeader(title: "Transitions") { dismiss() }
                summary(enabled: enabled)
                    .padding(.top, 8)
                swipeEntry
                    .padding(.top, 14)
                shortcuts
                    .padding(.top, 14)
                speedModeRow
                    .padding(.top, 6)
                resetRow
                    .padding(.top, 4)
                if !bleManager.boardSupportsTransitionMask && bleManager.isConnected {
                    Text("This display's firmware is older than BLE protocol 1.12, so it picks from every transition no matter what is switched on here. Flash the new firmware to use this list.")
                        .themeText(.footnote)
                        .foregroundStyle(theme.inkSoft)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 12)
                }
                ThemedDivider()
                    .padding(.vertical, 18)
                ForEach(TransitionCatalog.groups) { group in
                    groupHeader(group)
                    ForEach(group.ids, id: \.self) { tid in
                        if let info = TransitionCatalog.info(id: tid) {
                            row(info)
                                .padding(.bottom, 16)
                        }
                    }
                }
                Text("Previews are drawn by the display's own transition code, so they show the real effect; only their speed is estimated. They go from the current song's cover to the next one in your queue (sample covers when either is missing). New songs and covers from the display's memory both pick from every transition switched on here; \u{201C}Quick only\u{201D} keeps new songs fast.")
                    .themeText(.statCaption)
                    .foregroundStyle(theme.inkFaint)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)
            }
            .padding(.horizontal, theme.margin + 4)
            .padding(.bottom, 32)
        }
        .background(theme.background.ignoresSafeArea())
        .onChange(of: disabledRaw) { _ in
            bleManager.applyTransitionPrefs()
        }
        .onChange(of: randomSpeed) { _ in
            bleManager.applyTransitionSpeeds()
        }
        // Previews go from the current song's cover (A) to the next queued song's (B). The samples
        // show until those are ready; a song change while the picker is open re-reads both.
        .onAppear { refreshPreviewCovers(opening: true) }
        .onChange(of: bleManager.boardFrame) { _ in refreshPreviewCovers(opening: false) }
        .onChange(of: bleManager.currentAlbumArt) { _ in refreshPreviewCovers(opening: false) }
    }

    private func refreshPreviewCovers(opening: Bool) {
        TransitionPreviewStore.shared.refreshCovers(
            boardFrame: bleManager.boardFrame,
            albumArt: bleManager.currentAlbumArt,
            opening: opening
        )
    }

    private func summary(enabled: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(enabled) of \(TransitionCatalog.all.count) switched on")
                .themeText(.row)
                .foregroundStyle(theme.ink)
            Text(enabled == 0
                 ? "None switched on: new covers appear at once, with no transition."
                 : "The display picks one of the switched-on transitions at random each time the cover changes.")
                .themeText(.footnote)
                .foregroundStyle(theme.inkSoft)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Opens the swipe deck: one big card per transition, right = keep on, left = switch off.
    private var swipeEntry: some View {
        Button { showSwipe = true } label: {
            HStack(spacing: 10) {
                Image(systemName: "rectangle.stack.fill")
                    .font(.system(size: 17, weight: .semibold))
                Text("Swipe through them")
                    .themeText(.button)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(theme.onPrimary)
            .padding(.horizontal, 18)
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(PrimaryButtonBackground())
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Shows each transition on its own card. Swipe right to keep it, left to switch it off.")
        .sheet(isPresented: $showSwipe) {
            TransitionSwipeView(bleManager: bleManager)
                .environment(\.theme, theme)
                .preferredColorScheme(theme.colorScheme)
        }
    }

    /// Puts every transition back to how it came: all switched on, every speed normal (random
    /// speed back to its default), and the swipe deck's preview speed back to 1x. Asks first.
    private var resetRow: some View {
        Button { confirmReset = true } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: 13, weight: .semibold))
                Text("Reset all transitions")
                    .themeText(.rowValue)
                    .underline()
            }
            .foregroundStyle(theme.destructive)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .confirmationDialog("Reset all transitions?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Reset", role: .destructive) { resetAll() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every transition is switched back on and every speed goes back to normal. Your swipes and custom speeds are cleared.")
        }
    }

    private func resetAll() {
        let listChanges = !disabledRaw.isEmpty
        speedEditing = nil
        speedsRaw = ""
        swipePreviewSpeedsRaw = "1"
        randomSpeed = TransitionSpeeds.randomDefault
        disabledRaw = ""
        // A changed list sends itself (onChange, which also sends the speeds); otherwise send the
        // speeds here, once.
        if !listChanges { bleManager.applyTransitionSpeeds() }
    }

    private var shortcuts: some View {
        HStack(spacing: 22) {
            shortcut("All on") { disabledRaw = "" }
            shortcut("All off") {
                disabledRaw = TransitionPrefs.raw(from: Set(TransitionCatalog.all.map(\.id)))
            }
            shortcut("Quick only") {
                disabledRaw = TransitionPrefs.raw(from: Set(TransitionCatalog.all.filter { !$0.quick }.map(\.id)))
            }
        }
    }

    /// Speed for every transition at once: Random (0.4x-1.3x each time), Slow (0.5x), Normal (1x) or
    /// Fast (1.3x). The per-transition speed buttons below still work; then no mode is highlighted.
    private var speedModeRow: some View {
        let current = TransitionSpeeds.mode(speedsRaw: speedsRaw, random: randomSpeed)
        return VStack(alignment: .leading, spacing: 4) {
            Text("Speed")
                .themeText(.row)
                .foregroundStyle(theme.ink)
            HStack(spacing: 0) {
                ForEach(TransitionSpeeds.Mode.allCases) { mode in
                    Button {
                        let s = TransitionSpeeds.settings(for: mode)
                        speedsRaw = s.raw
                        if randomSpeed != s.random {
                            randomSpeed = s.random  // its onChange sends the speeds
                        } else {
                            bleManager.applyTransitionSpeeds()
                        }
                    } label: {
                        HStack(spacing: 6) {
                            StateMarker(filled: current == mode, fillColor: theme.display, ringColor: theme.ringOff, size: 9)
                            Text(mode.title)
                                .themeText(.rowValue)
                                .foregroundStyle(current == mode ? theme.ink : theme.inkSoft)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                        }
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(mode.title) speed")
                    .accessibilityAddTraits(current == mode ? .isSelected : [])
                }
            }
            Text(speedModeNote(current))
                .themeText(.footnote)
                .foregroundStyle(theme.inkSoft)
                .fixedSize(horizontal: false, vertical: true)
            if bleManager.isConnected && !bleManager.boardSupportsSpeeds {
                Text("This display's firmware is older than BLE protocol 1.14, so it ignores speeds. Flash the new firmware to use them.")
                    .themeText(.footnote)
                    .foregroundStyle(theme.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func speedModeNote(_ mode: TransitionSpeeds.Mode?) -> String {
        switch mode {
        case .random?: return "Each time, a transition plays somewhere between 0.4x and 1.3x. New songs always play fast."
        case .slow?: return "Every transition plays at 0.5x, new songs too."
        case .normal?: return "Every transition plays at normal speed. New songs always play fast."
        case .fast?: return "Every transition plays at 1.3x, the fastest."
        case nil: return "Custom: you set some transitions' own speed with their speed button. Pick a mode to reset them all."
        }
    }

    private func speedPercent(_ id: Int) -> Int {
        TransitionSpeeds.parse(speedsRaw)[id] ?? TransitionSpeeds.normal
    }

    private func setSpeed(_ id: Int, _ percent: Int) {
        var speeds = TransitionSpeeds.parse(speedsRaw)
        speeds[id] = percent
        speedsRaw = TransitionSpeeds.raw(from: speeds)
    }

    /// Small button under a transition's name: shows its speed, opens the slider.
    private func speedButton(_ info: TransitionInfo) -> some View {
        let pct = speedPercent(info.id)
        let open = speedEditing == info.id
        let custom = pct != TransitionSpeeds.normal
        return Button {
            withAnimation(.easeOut(duration: 0.15)) { speedEditing = open ? nil : info.id }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "gauge.with.dots.needle.33percent")
                    .font(.system(size: 11, weight: .semibold))
                Text(custom ? TransitionSpeeds.label(pct) : (randomSpeed ? "random" : "normal"))
                    .themeText(.statCaption)
                    .monospacedDigit()
            }
            .foregroundStyle(custom || open ? theme.ink : theme.inkFaint)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .overlay(Capsule().stroke(open ? theme.ink : theme.ringOff.opacity(0.6), lineWidth: 1))
            // Small pill, 44 pt tall target.
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, -10)
        .accessibilityLabel("\(info.name) speed")
        .accessibilityValue(custom ? TransitionSpeeds.label(pct) : (randomSpeed ? "Random" : "Normal"))
        .accessibilityHint(open ? "Closes the speed slider" : "Opens a speed slider")
    }

    /// 0.4x...1.3x slider for one transition; the example above plays at the chosen speed.
    private func speedSlider(_ info: TransitionInfo) -> some View {
        let pct = speedPercent(info.id)
        let binding = Binding<Double>(
            get: { Double(pct) },
            set: { setSpeed(info.id, Int(($0 / 5).rounded() * 5)) }
        )
        return VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("0.4x").themeText(.statCaption).foregroundStyle(theme.inkFaint)
                Slider(
                    value: binding,
                    in: Double(TransitionSpeeds.minPercent)...Double(TransitionSpeeds.maxPercent),
                    onEditingChanged: { editing in
                        // One write when the finger lifts, not one per step.
                        if !editing { bleManager.applyTransitionSpeeds() }
                    }
                )
                .tint(theme.sliderTint)
                .accessibilityLabel("\(info.name) speed")
                .accessibilityValue(TransitionSpeeds.label(pct))
                Text("1.3x").themeText(.statCaption).foregroundStyle(theme.inkFaint)
            }
            HStack {
                Text(TransitionSpeeds.label(pct))
                    .themeText(.rowValue)
                    .monospacedDigit()
                    .foregroundStyle(theme.ink)
                Spacer()
                Button {
                    setSpeed(info.id, TransitionSpeeds.normal)
                    bleManager.applyTransitionSpeeds()
                } label: {
                    Text(randomSpeed ? "Back to random" : "Back to normal")
                        .themeText(.rowValue)
                        .foregroundStyle(pct == TransitionSpeeds.normal ? theme.inkFaint : theme.ink)
                        .underline()
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(pct == TransitionSpeeds.normal)
            }
        }
        .padding(.leading, 98)
    }

    private func shortcut(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .themeText(.rowValue)
                .foregroundStyle(theme.ink)
                .underline()
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Theme heading with a one-tap switch for the whole family: all on, or all off if they already are.
    private func groupHeader(_ group: TransitionCatalog.Group) -> some View {
        let off = TransitionPrefs.disabledSet(from: disabledRaw)
        let onCount = group.ids.filter { !off.contains($0) }.count
        let allOn = onCount == group.ids.count
        return HStack(alignment: .firstTextBaseline) {
            Text(group.name)
                .themeText(.eyebrow)
                .foregroundStyle(theme.inkFaint)
            Text("\(onCount)/\(group.ids.count)")
                .themeText(.statCaption)
                .foregroundStyle(theme.inkFaint)
            Spacer()
            Button {
                // "Only these": everything outside this group off, this group on.
                let outside = Set(TransitionCatalog.all.map(\.id)).subtracting(group.ids)
                disabledRaw = TransitionPrefs.raw(from: outside)
            } label: {
                Text("Only these")
                    .themeText(.rowValue)
                    .foregroundStyle(theme.ink)
                    .underline()
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button {
                var next = off
                if allOn { group.ids.forEach { next.insert($0) } } else { group.ids.forEach { next.remove($0) } }
                disabledRaw = TransitionPrefs.raw(from: next)
            } label: {
                Text(allOn ? "All off" : "All on")
                    .themeText(.rowValue)
                    .foregroundStyle(theme.ink)
                    .underline()
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.top, 10)
        .accessibilityElement(children: .combine)
    }

    private func isOn(_ info: TransitionInfo) -> Binding<Bool> {
        Binding(
            get: { !TransitionPrefs.disabledSet(from: disabledRaw).contains(info.id) },
            set: { on in
                var off = TransitionPrefs.disabledSet(from: disabledRaw)
                if on { off.remove(info.id) } else { off.insert(info.id) }
                disabledRaw = TransitionPrefs.raw(from: off)
            }
        )
    }

    private func row(_ info: TransitionInfo) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            rowMain(info)
            if speedEditing == info.id {
                speedSlider(info)
                    .transition(.opacity)
            }
        }
    }

    private func rowMain(_ info: TransitionInfo) -> some View {
        let on = isOn(info)
        return HStack(alignment: .center, spacing: 14) {
            LoopingTransitionPreview(id: info.id, duration: info.duration,
                                     speed: Double(speedPercent(info.id)) / 100)
                .frame(width: 84, height: 84)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .opacity(on.wrappedValue ? 1 : 0.35)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(info.name)
                        .themeText(.row)
                        .foregroundStyle(on.wrappedValue ? theme.ink : theme.inkFaint)
                    if info.quick {
                        Text("quick")
                            .themeText(.statCaption)
                            .foregroundStyle(theme.inkFaint)
                    }
                }
                Text(info.blurb)
                    .themeText(.footnote)
                    .foregroundStyle(theme.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
                speedButton(info)
                    .padding(.top, 2)
            }
            Spacer(minLength: 8)
            Toggle("", isOn: on)
                .labelsHidden()
                .toggleStyle(ThemedToggleStyle())
                .frame(width: 60)
                .accessibilityLabel(info.name)
        }
        .accessibilityElement(children: .contain)
    }
}
