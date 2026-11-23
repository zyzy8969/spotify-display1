import SwiftUI

/// Swipe through every transition one card at a time, like a dating app: right (or the heart) keeps
/// it switched on, left (or the cross) switches it off. Each card loops the real effect from the
/// current song's cover to the next queued one (`TransitionPreviewStore`, same as the picker rows).
/// Every swipe writes straight to `TransitionPrefs`, so leaving halfway keeps what was decided.
/// Opened from `TransitionPickerView`, whose `onChange(of: disabledRaw)` (still live under this
/// sheet) sends the new mask to the board, so this view doesn't send it a second time.
struct TransitionSwipeView: View {
    @ObservedObject var bleManager: BLEManager

    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(TransitionPrefs.storageKey) private var disabledRaw = ""
    /// How fast the card's example plays, for watching an effect slowly or at full pace. Several can
    /// be picked: each loop then plays at the next one in turn. Only the preview: it doesn't change
    /// the speed the board plays at (that's the picker's Speed row). Stored as "0.5,1.3".
    @AppStorage(Self.previewSpeedsKey) private var previewSpeedsRaw = "1"
    static let previewSpeedsKey = "swipePreviewSpeeds"
    private let previewSpeeds: [(label: String, rate: String, value: Double)] = [
        ("Slo-mo", "0.25x", 0.25), ("Slow", "0.5x", 0.5), ("Normal", "1x", 1.0), ("Fast", "1.3x", 1.3),
    ]

    private struct Decision {
        let id: Int
        let liked: Bool
        /// Whether it was on before this swipe, so undo puts it back exactly.
        let wasOn: Bool
    }

    private let deck = TransitionCatalog.all
    @State private var index = 0
    @State private var history: [Decision] = []
    @State private var drag: CGSize = .zero
    /// Card flying off screen: +1 right (keep), -1 left (off).
    @State private var flying: CGFloat = 0

    /// How far a drag must go before letting go counts as a swipe.
    private let threshold: CGFloat = 110

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: "Swipe transitions") { dismiss() }
                .padding(.horizontal, theme.margin + 4)
            progress
                .padding(.horizontal, theme.margin + 4)
                .padding(.top, 6)
            Spacer(minLength: 12)
            if index < deck.count {
                speedPicker
                    .padding(.horizontal, theme.margin + 4)
                    .padding(.top, 10)
                Spacer(minLength: 8)
                cardStack
                    .padding(.horizontal, theme.margin + 4)
                Spacer(minLength: 16)
                controls
                    .padding(.bottom, 28)
            } else {
                finished
                    .padding(.horizontal, theme.margin + 4)
                Spacer()
            }
        }
        .background(theme.background.ignoresSafeArea())
        .onAppear {
            TransitionPreviewStore.shared.refreshCovers(
                boardFrame: bleManager.boardFrame, albumArt: bleManager.currentAlbumArt, opening: true)
            prefetch()
        }
        .onChange(of: bleManager.boardFrame) { _ in refreshCovers() }
        .onChange(of: bleManager.currentAlbumArt) { _ in refreshCovers() }
    }

    private func refreshCovers() {
        TransitionPreviewStore.shared.refreshCovers(
            boardFrame: bleManager.boardFrame, albumArt: bleManager.currentAlbumArt, opening: false)
    }

    /// Start rendering the next two cards so they're ready by the time they come up.
    private func prefetch() {
        for i in (index + 1)...(index + 2) where i < deck.count {
            TransitionPreviewStore.shared.request(deck[i].id)
        }
    }

    // MARK: - Progress

    private var progress: some View {
        let liked = history.filter(\.liked).count
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("\(min(index + 1, deck.count)) of \(deck.count)")
                    .themeText(.rowValue)
                    .monospacedDigit()
                    .foregroundStyle(theme.ink)
                Spacer()
                Text("\(liked) kept \u{00B7} \(history.count - liked) off")
                    .themeText(.statCaption)
                    .monospacedDigit()
                    .foregroundStyle(theme.inkSoft)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(theme.ringOff.opacity(0.35))
                    Capsule().fill(theme.display)
                        .frame(width: geo.size.width * CGFloat(index) / CGFloat(max(1, deck.count)))
                }
            }
            .frame(height: 4)
            .accessibilityHidden(true)
        }
    }

    // MARK: - Preview speed

    /// Picked speeds in the menu's order (slowest first); never empty.
    private var selectedSpeeds: [Double] {
        let picked = Set(previewSpeedsRaw.split(separator: ",").compactMap { Double($0) })
        let ordered = previewSpeeds.map(\.value).filter { picked.contains($0) }
        return ordered.isEmpty ? [1.0] : ordered
    }

    /// Tap toggles a speed in or out; the last one picked can't be removed.
    private func toggleSpeed(_ value: Double) {
        var picked = Set(selectedSpeeds)
        if picked.contains(value) {
            guard picked.count > 1 else { return }
            picked.remove(value)
        } else {
            picked.insert(value)
        }
        previewSpeedsRaw = previewSpeeds.map(\.value).filter { picked.contains($0) }
            .map { String($0) }.joined(separator: ",")
    }

    private var speedPicker: some View {
        HStack(spacing: 0) {
            ForEach(previewSpeeds, id: \.value) { option in
                let selected = selectedSpeeds.contains(option.value)
                Button {
                    toggleSpeed(option.value)
                } label: {
                    VStack(spacing: 1) {
                        Text(option.label)
                            .themeText(.rowValue)
                            .foregroundStyle(selected ? theme.ink : theme.inkSoft)
                        Text(option.rate)
                            .themeText(.statCaption)
                            .monospacedDigit()
                            .foregroundStyle(theme.inkFaint)
                    }
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(
                        Capsule().fill(selected ? theme.ringOff.opacity(0.3) : .clear)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(option.label) preview, \(option.rate)")
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(3)
        .overlay(Capsule().stroke(theme.ringOff.opacity(0.5), lineWidth: 1))
    }

    // MARK: - Cards

    private var cardStack: some View {
        ZStack {
            // The card underneath, so the deck reads as a stack.
            if index + 1 < deck.count {
                card(deck[index + 1], live: false)
                    .scaleEffect(0.94 + 0.06 * min(1, abs(drag.width) / threshold))
                    .opacity(0.6)
                    .accessibilityHidden(true)
            }
            card(deck[index], live: true)
                .offset(x: drag.width + flying * 600, y: drag.height * 0.25)
                .rotationEffect(.degrees(Double(drag.width + flying * 600) / 22))
                .overlay(stamps)
                .gesture(swipeGesture)
                .accessibilityElement(children: .combine)
                .accessibilityHint("Swipe right to keep it on, left to switch it off")
                .accessibilityAction(named: "Keep on") { decide(liked: true) }
                .accessibilityAction(named: "Switch off") { decide(liked: false) }
        }
        .id(index)
    }

    private func card(_ info: TransitionInfo, live: Bool) -> some View {
        let wasOn = !TransitionPrefs.disabledSet(from: disabledRaw).contains(info.id)
        return VStack(alignment: .leading, spacing: 12) {
            Group {
                if live {
                    LoopingTransitionPreview(id: info.id, duration: info.duration,
                                         speeds: selectedSpeeds, showsSpeed: true)
                } else {
                    SampleCover(variant: 0)
                }
            }
            .aspectRatio(1, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: theme.artCornerRadius + 4, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(info.name)
                        .themeText(.heading)
                        .foregroundStyle(theme.ink)
                    if info.quick {
                        Text("quick")
                            .themeText(.statCaption)
                            .foregroundStyle(theme.inkFaint)
                    }
                    Spacer()
                    Text(wasOn ? "on now" : "off now")
                        .themeText(.statCaption)
                        .foregroundStyle(theme.inkFaint)
                }
                Text(info.blurb)
                    .themeText(.footnote)
                    .foregroundStyle(theme.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 4)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: theme.artCornerRadius + 10, style: .continuous)
                .fill(theme.artSurface)
                .shadow(color: .black.opacity(0.12), radius: 12, y: 6)
        )
        .overlay(
            RoundedRectangle(cornerRadius: theme.artCornerRadius + 10, style: .continuous)
                .stroke(theme.ringOff.opacity(0.4), lineWidth: 1)
        )
    }

    /// "KEEP" / "NOPE" stamps that fade in with the drag.
    private var stamps: some View {
        let x = drag.width + flying * threshold
        return ZStack(alignment: .top) {
            stamp("KEEP", color: theme.spotify, angle: -14)
                .opacity(Double(max(0, min(1, x / threshold))))
                .frame(maxWidth: .infinity, alignment: .leading)
            stamp("NOPE", color: theme.destructive, angle: 14)
                .opacity(Double(max(0, min(1, -x / threshold))))
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(28)
        .frame(maxHeight: .infinity, alignment: .top)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func stamp(_ text: String, color: Color, angle: Double) -> some View {
        Text(text)
            .font(.system(size: 30, weight: .heavy, design: .rounded))
            .foregroundStyle(color)
            .padding(.horizontal, 10)
            .padding(.vertical, 2)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(color, lineWidth: 3))
            .rotationEffect(.degrees(angle))
    }

    private var swipeGesture: some Gesture {
        DragGesture()
            .onChanged { drag = $0.translation }
            .onEnded { value in
                // A quick flick counts even if it didn't travel far.
                let projected = value.predictedEndTranslation.width
                if value.translation.width > threshold || projected > threshold * 2.5 {
                    decide(liked: true)
                } else if value.translation.width < -threshold || projected < -threshold * 2.5 {
                    decide(liked: false)
                } else {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) { drag = .zero }
                }
            }
    }

    // MARK: - Buttons

    private var controls: some View {
        HStack(spacing: 28) {
            roundButton(system: "xmark", tint: theme.destructive, size: 64, label: "Switch off") {
                decide(liked: false)
            }
            roundButton(system: "arrow.uturn.backward", tint: theme.inkSoft, size: 46, label: "Undo") {
                undo()
            }
            .disabled(history.isEmpty)
            .opacity(history.isEmpty ? 0.35 : 1)
            roundButton(system: "heart.fill", tint: theme.spotify, size: 64, label: "Keep on") {
                decide(liked: true)
            }
        }
    }

    private func roundButton(system: String, tint: Color, size: CGFloat, label: String,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: size * 0.38, weight: .bold))
                .foregroundStyle(tint)
                .frame(width: size, height: size)
                .background(Circle().fill(theme.artSurface))
                .overlay(Circle().stroke(tint.opacity(0.5), lineWidth: 2))
                .shadow(color: .black.opacity(0.08), radius: 6, y: 3)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    // MARK: - Done

    private var finished: some View {
        let kept = history.filter(\.liked).count
        let enabled = TransitionPrefs.enabledCount(disabledRaw: disabledRaw)
        return VStack(alignment: .leading, spacing: 14) {
            Text("All done")
                .themeText(.heading)
                .foregroundStyle(theme.ink)
            Text("You kept \(kept) of the \(history.count) you swiped. \(enabled) of \(deck.count) are switched on now; the display picks from those at random.")
                .themeText(.lead)
                .foregroundStyle(theme.inkSoft)
                .fixedSize(horizontal: false, vertical: true)
            if enabled == 0 {
                Text("None are on, so new covers will appear at once with no transition.")
                    .themeText(.footnote)
                    .foregroundStyle(theme.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 22) {
                textButton("Undo last") { undo() }
                textButton("Start over") {
                    history = []
                    index = 0
                    prefetch()
                }
                textButton("Done") { dismiss() }
            }
            .padding(.top, 4)
        }
    }

    private func textButton(_ title: String, action: @escaping () -> Void) -> some View {
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

    // MARK: - State

    private func decide(liked: Bool) {
        guard index < deck.count, flying == 0 else { return }
        let info = deck[index]
        var off = TransitionPrefs.disabledSet(from: disabledRaw)
        history.append(Decision(id: info.id, liked: liked, wasOn: !off.contains(info.id)))
        if liked { off.remove(info.id) } else { off.insert(info.id) }
        disabledRaw = TransitionPrefs.raw(from: off)

        if reduceMotion {
            advance()
            return
        }
        withAnimation(.easeIn(duration: 0.22)) { flying = liked ? 1 : -1 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) { advance() }
    }

    private func advance() {
        flying = 0
        drag = .zero
        index += 1
        prefetch()
    }

    private func undo() {
        // Not while a card is flying off: its pending advance() would skip past the restored card.
        guard flying == 0, let last = history.popLast() else { return }
        var off = TransitionPrefs.disabledSet(from: disabledRaw)
        if last.wasOn { off.remove(last.id) } else { off.insert(last.id) }
        disabledRaw = TransitionPrefs.raw(from: off)
        flying = 0
        drag = .zero
        index = max(0, index - 1)
    }
}
