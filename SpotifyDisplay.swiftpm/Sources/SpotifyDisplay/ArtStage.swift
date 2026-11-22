import SwiftUI
import UIKit

// MARK: - Album art

/// The cover as the keychain shows it. A new cover replaces the old one in one piece, like the
/// firmware's whole-frame draw; send progress lives in the strip below, not on the art.
///
/// Exact mirror (BLE_PROTOCOL 1.13 firmware): the board announces `TRANSITION_START` just before it
/// draws. `TransitionMirror` renders that transition with the board's own code (TransitionsCore) and
/// this view flips through the frames on the board's clock, so the phone plays the same effect at the
/// same time as the keychain, then ends on the real cover (`image`) once the screen hands it over.
/// Older firmware: the effect it announced after drawing (`event`) is replayed approximately
/// (`TransitionStage`). Reduce Motion: the cover cuts.
struct ArtStage: View {
    let image: UIImage?
    let side: CGFloat
    let label: String
    let value: String
    /// Newest `TRANSITION:` announcement from the board, if any.
    var event: TransitionEvent? = nil

    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var mirror = TransitionMirror.shared

    // Approximate replay (older firmware).
    /// The cover that was showing before the latest change (kept only while its transition plays).
    @State private var outgoing: UIImage?
    /// The picture last seen, so a change knows what it replaces.
    @State private var previous: UIImage?
    @State private var playStart: Date?
    @State private var playID = 22
    @State private var playDuration = 0.4
    @State private var playGen = 0
    @State private var lastEventID: UUID?

    // Exact mirror.
    /// Mirror playback that is over (the view shows `image` again).
    @State private var finishedMirrorID: UUID?
    /// The screen handed over the new cover for this playback.
    @State private var coverArrivedFor: UUID?

    /// An announcement older than this belongs to an earlier song, not to this cover.
    private let freshWindow: TimeInterval = 10
    /// After the board's transition ends, keep its last frame up to this long while waiting for the
    /// screen to hand over the new cover (a fresh send swaps it only after the board's ACK).
    private let coverHold: TimeInterval = 3

    var body: some View {
        ZStack {
            if let pb = activeMirror {
                mirrorLayer(pb)
            } else if let start = playStart, outgoing != nil {
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
        .onAppear {
            previous = image
            if let pb = mirror.playback {
                // A view made after the playback began (back from another page) only joins a running one.
                if Date() >= pb.end { finishedMirrorID = pb.id } else { watchMirror(pb.id) }
            }
        }
        .onChange(of: imageID) { _ in imageDidChange() }
        .onChange(of: mirror.playback?.id) { id in
            if let id { watchMirror(id) }
        }
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

    /// The board transition being mirrored right now, if any.
    private var activeMirror: TransitionMirror.Playback? {
        guard !reduceMotion, let pb = mirror.playback, pb.id != finishedMirrorID else { return nil }
        return pb
    }

    /// Precomputed frames picked by the clock: no per-frame masks or effects on the main thread.
    private func mirrorLayer(_ pb: TransitionMirror.Playback) -> some View {
        TimelineView(.animation) { timeline in
            let now = timeline.date
            if now >= pb.end, coverArrivedFor == pb.id {
                artLayer(image)
            } else if let frame = pb.frame(at: now) {
                Image(decorative: frame, scale: 1)
                    .resizable()
                    .interpolation(.medium)
                    .frame(width: side, height: side)
            } else {
                // Not rendered yet: the board is still showing the old cover too.
                artLayer(image)
            }
        }
    }

    /// Ends the playback once the board is done and the real cover is here (or the hold ran out).
    private func watchMirror(_ id: UUID) {
        Task { @MainActor in
            while true {
                try? await Task.sleep(nanoseconds: 100_000_000)
                guard let pb = mirror.playback, pb.id == id, finishedMirrorID != id else { return }
                let now = Date()
                let ended = now >= pb.end
                let done = ended && (coverArrivedFor == id || now >= pb.end.addingTimeInterval(coverHold))
                if done || now.timeIntervalSince(pb.start) > 30 {
                    finishedMirrorID = id
                    return
                }
            }
        }
    }

    private func imageDidChange() {
        let old = previous
        previous = image
        if let pb = mirror.playback, coverArrivedFor != pb.id,
           pb.id != finishedMirrorID || Date().timeIntervalSince(pb.end) < freshWindow {
            // The cover the board is drawing (or just drew): the mirror already shows this change,
            // so no second transition on top of it.
            coverArrivedFor = pb.id
            playStart = nil
            outgoing = nil
            return
        }
        guard !reduceMotion, old != nil, image != nil else {
            playStart = nil
            outgoing = nil
            return
        }
        if !mirror.boardAnnouncesStart, let e = event, e.id != lastEventID,
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
