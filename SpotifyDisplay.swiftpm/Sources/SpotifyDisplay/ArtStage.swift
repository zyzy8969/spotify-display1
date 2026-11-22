import SwiftUI
import UIKit

// MARK: - Album art

/// The cover as the keychain shows it. A new cover replaces the old one in one piece, like the
/// firmware's whole-frame draw; send progress lives in the strip below, not on the art. When the board
/// announced the transition it just drew (`event`), the same effect is replayed here (an approximation:
/// see `TransitionStage`); otherwise, and with Reduce Motion, the cover crossfades or cuts.
struct ArtStage: View {
    let image: UIImage?
    let side: CGFloat
    let label: String
    let value: String
    /// Newest `TRANSITION:` announcement from the board, if any.
    var event: TransitionEvent? = nil

    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The cover that was showing before the latest change (kept only while its transition plays).
    @State private var outgoing: UIImage?
    /// The picture last seen, so a change knows what it replaces.
    @State private var previous: UIImage?
    @State private var playStart: Date?
    @State private var playID = 22
    @State private var playDuration = 0.4
    @State private var playGen = 0
    @State private var lastEventID: UUID?

    /// An announcement older than this belongs to an earlier song, not to this cover.
    private let freshWindow: TimeInterval = 10

    var body: some View {
        ZStack {
            if let start = playStart, outgoing != nil {
                TimelineView(.animation) { timeline in
                    let elapsed = timeline.date.timeIntervalSince(start)
                    let p = CGFloat(max(0, min(1, elapsed / playDuration)))
                    TransitionStage(id: playID, progress: p) {
                        artLayer(outgoing)
                    } new: {
                        artLayer(image)
                    }
                }
            } else {
                artLayer(image)
            }
        }
        .onAppear { previous = image }
        .onChange(of: imageID) { _ in imageDidChange() }
        .frame(width: side, height: side)
        .background(theme.artSurface)
        .clipShape(RoundedRectangle(cornerRadius: theme.artCornerRadius, style: .continuous))
        .overlay(border)
        .shadow(color: theme.artShadowColor, radius: theme.artShadowRadius, x: 0, y: theme.artShadowY)
        .background(frameDoodle)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(value)
        .accessibilityAddTraits(.isImage)
    }

    /// Identity of the picture, so a new cover changes as one piece (Reduce Motion: cut).
    private var imageID: ObjectIdentifier? {
        image.map { ObjectIdentifier($0) }
    }

    private func imageDidChange() {
        let old = previous
        previous = image
        guard !reduceMotion, old != nil, image != nil else {
            playStart = nil
            outgoing = nil
            return
        }
        if let e = event, e.id != lastEventID,
           Date().timeIntervalSince(e.date) < freshWindow,
           let info = TransitionCatalog.info(named: e.name) {
            lastEventID = e.id
            playID = info.id
            playDuration = info.duration
        } else {
            playID = 22  // no announcement for this change: plain crossfade
            playDuration = 0.4
        }
        outgoing = old
        playStart = Date()
        playGen += 1
        let gen = playGen
        let wait = UInt64((playDuration + 0.1) * 1_000_000_000)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: wait)
            if gen == playGen {
                playStart = nil
                outgoing = nil
            }
        }
    }

    @ViewBuilder
    private func artLayer(_ image: UIImage?) -> some View {
        if let image {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: side, height: side)
                .clipped()
        } else {
            ArtPlaceholder(side: side)
        }
    }

    @ViewBuilder
    private var border: some View {
        if let color = theme.artBorder {
            RoundedRectangle(cornerRadius: theme.artCornerRadius, style: .continuous)
                .stroke(color, lineWidth: 1)
        }
    }

    /// Crayon only: a coloured hand-drawn outline sitting just behind the cover, like a shadow
    /// someone coloured in.
    @ViewBuilder
    private var frameDoodle: some View {
        if let color = theme.artFrame {
            ThemedStroke(
                shape: WobbleRoundedRect(cornerRadius: 10, amplitude: theme.wobble * 1.8, seed: 61),
                color: color,
                lineWidth: 3
            )
            .offset(x: 6, y: 7)
        }
    }
}

