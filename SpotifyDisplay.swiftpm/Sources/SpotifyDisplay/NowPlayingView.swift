import SwiftUI
import UIKit

// MARK: - Layout metrics

enum ArtMetrics {
    static let maxSide: CGFloat = 300

    /// Square side for the cover. Depends only on the safe-area size of the screen, never on
    /// sibling views, so badges, progress and errors coming and going cannot resize the art.
    static func side(for size: CGSize, margin: CGFloat) -> CGFloat {
        let byWidth = size.width - margin * 2
        let byHeight = size.height * 0.46
        return max(120, min(maxSide, byWidth, byHeight)).rounded(.down)
    }

    /// Fixed gap between the header and the art. Only the Spacer *below* the track info flexes,
    /// so nothing that changes height below the art can move it.
    static func topGap(for size: CGSize) -> CGFloat {
        min(40, max(8, size.height * 0.035))
    }

    /// Bottom breathing room: the home indicator already reserves space on Face ID phones;
    /// home-button phones (no bottom inset) need a little more.
    static func bottomPadding(safeAreaBottom: CGFloat) -> CGFloat {
        safeAreaBottom > 0 ? 4 : 14
    }
}

// MARK: - Now playing

/// Main screen while signed in to Spotify. Covers the Crayon "playing" and "sending" artboards
/// (and their Quiet / Serif counterparts) — sending is a state of this screen, not a new screen.
struct NowPlayingScreen: View {
    @ObservedObject var bleManager: BLEManager
    @ObservedObject var spotifyManager: SpotifyManager
    let showStatsLink: Bool
    let onOpen: (Panel) -> Void

    @Environment(\.theme) private var theme
    /// What the keychain shows right now, decoded once per change instead of on every render.
    @State private var shownImage: UIImage?
    /// A fresh send's new cover, held back until the board confirms it. The firmware draws a new
    /// frame only when it is whole (with a transition, just before its ACK) and leaves the old
    /// picture up if the send fails, so the app does the same.
    @State private var pendingImage: UIImage?
    /// Newest transfer-log entry when the pending send began; a newer non-cache entry at the end
    /// of the send means it succeeded.
    @State private var pendingSinceLogID: UUID?
    /// The old cover, kept up while a transition's frames are being computed.
    @State private var heldImage: UIImage?
    /// The board-transition frame on screen right now (nil when no transition is playing).
    @State private var transitionFrame: CGImage?
    /// Bumped per cover change so an older transition stops playing.
    @State private var transitionToken = 0
    /// Cache-hit log entry already animated, so a later art refresh doesn't replay it.
    @State private var animatedLogID: UUID?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            let side = ArtMetrics.side(for: geo.size, margin: theme.margin)
            let topGap = ArtMetrics.topGap(for: geo.size)
            let bottomPad = ArtMetrics.bottomPadding(safeAreaBottom: geo.safeAreaInsets.bottom)
            FitOrScroll {
                column(side: side, topGap: topGap, bottomPad: bottomPad)
            }
        }
        .onAppear {
            shownImage = Self.decode(bleManager.currentAlbumArt)
        }
        .onChange(of: bleManager.currentAlbumArt) { newData in
            // During a fresh send the stage handler below picks the art up; anything else
            // (a confirmed cache hit, the paused preview) is already what the display shows.
            guard bleManager.sendStage != .preparingFresh else { return }
            pendingImage = nil
            show(Self.decode(newData), with: cacheHitTransition())
        }
        // The board starts its transition as soon as the last byte lands, so start ours when
        // every byte has been handed to Bluetooth rather than waiting for the ACK (which only
        // comes after the board has finished drawing and saving).
        .onChange(of: bleManager.transferProgress) { progress in
            guard progress >= 1, bleManager.sendStage == .preparingFresh, let pending = pendingImage else { return }
            pendingImage = nil
            show(pending, with: bleManager.freshTransition)
        }
        // `sendStage` returns to idle on every exit from processTrack (success, error, skip).
        .onChange(of: bleManager.sendStage) { stage in
            stageDidChange(stage)
        }
    }

    /// The transition the board just played for a cache hit, read from its `TRANSITION:` reply
    /// (logged with the hit). The board has already finished it by the time the cover arrives
    /// here, so on a hit the app plays it slightly after the keychain.
    private func cacheHitTransition() -> BoardTransition? {
        guard let entry = bleManager.transferLog.last, entry.cacheHit, entry.id != animatedLogID,
              Date().timeIntervalSince(entry.timestamp) < 15 else { return nil }
        animatedLogID = entry.id
        return BoardTransition(name: entry.transitionName)
    }

    /// Replaces the cover, playing the board's own `transition` frames (`BoardTransitionRenderer`)
    /// at the board's pace. A plain cut when there is no transition, no previous cover, or Reduce
    /// Motion is on.
    private func show(_ image: UIImage?, with transition: BoardTransition?) {
        transitionToken &+= 1
        let token = transitionToken
        guard let transition, !reduceMotion, let old = shownImage, let new = image else {
            heldImage = nil
            transitionFrame = nil
            shownImage = image
            return
        }
        heldImage = old
        transitionFrame = nil
        shownImage = new
        Task { @MainActor in
            let frames = await Task.detached(priority: .userInitiated) {
                BoardTransitionRenderer.frames(transition, from: old, to: new)
            }.value
            guard token == transitionToken else { return }
            heldImage = nil
            guard let frames, !frames.isEmpty else { return }
            let interval = transition.duration / Double(frames.count)
            for frame in frames {
                guard token == transitionToken else { return }
                transitionFrame = frame
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
            guard token == transitionToken else { return }
            transitionFrame = nil
        }
    }

    private func stageDidChange(_ stage: SendStage) {
        switch stage {
        case .preparingFresh:
            // `processTrack` sets the stage and the new art in the same turn, so the art is
            // already current here, even on a retry that sends identical bytes.
            pendingImage = Self.decode(bleManager.currentAlbumArt)
            pendingSinceLogID = bleManager.transferLog.last?.id
        case .idle:
            guard let pending = pendingImage else { return }
            let last = bleManager.transferLog.last
            let succeeded = last.map { $0.id != pendingSinceLogID && !$0.cacheHit } ?? false
            // Nothing to mirror without a display: show the song's cover rather than a stale one.
            if succeeded || !bleManager.isConnected {
                show(pending, with: succeeded ? bleManager.freshTransition : nil)
            }
            pendingImage = nil
            pendingSinceLogID = nil
        case .checking:
            break
        }
    }

    private func column(side: CGFloat, topGap: CGFloat, bottomPad: CGFloat) -> some View {
        VStack(spacing: 0) {
            StatusHeader(
                spotifyOn: spotifyManager.isAuthenticated,
                displayOn: bleManager.isConnected,
                showStatsLink: showStatsLink,
                onOpen: onOpen
            )
            Color.clear.frame(height: topGap)
            ArtStage(
                image: shownImage,
                held: heldImage,
                frame: transitionFrame,
                side: side,
                label: artLabel,
                value: artValue
            )
            LiveStrip(state: stripState)
                .frame(width: side)
                .padding(.top, 10)
            TrackInfo(title: trackTitle, subtitle: trackSubtitle)
                .frame(width: side)
                .padding(.top, 20)
            Spacer(minLength: 16)
            PlaybackControls(spotifyManager: spotifyManager)
            NowPlayingFooter(
                primary: footerPrimary,
                secondary: footerSecondary,
                live: showStatsLink ? bleManager.currentLivePhase : nil
            )
            .padding(.top, 6)
        }
        .padding(.horizontal, theme.margin)
        .padding(.bottom, bottomPad)
        .frame(maxWidth: .infinity)
    }

    // MARK: Derived state (read-only views of BLEManager / SpotifyManager)

    private var stripState: StripState {
        StripState.derive(
            isTransferring: bleManager.isTransferring,
            progress: bleManager.transferProgress,
            stage: bleManager.sendStage,
            lastResult: bleManager.lastTransferResult,
            lastEntry: bleManager.transferLog.last
        )
    }

    private static func decode(_ data: Data?) -> UIImage? {
        guard let data else { return nil }
        return UIImage(data: data)
    }

    private var trackTitle: String {
        spotifyManager.currentTrack?.name ?? theme.id.text(.nothingPlaying)
    }

    private var trackSubtitle: String? {
        guard let track = spotifyManager.currentTrack else { return theme.id.text(.playSomething) }
        let artists = track.artists.map(\.name).joined(separator: ", ")
        return artists.isEmpty ? nil : artists
    }

    private var artLabel: String {
        if let album = spotifyManager.currentTrack?.album?.name, !album.isEmpty {
            return "Album art, \(album)"
        }
        return "Album art"
    }

    private var artValue: String {
        if case .sending(let progress) = stripState {
            return "Sending the new cover to the display, \(Int((progress * 100).rounded())) percent"
        }
        return spotifyManager.isPlaying ? "" : "Paused"
    }

    private var footerPrimary: String {
        if case .sending(let progress) = stripState {
            return "\(theme.id.text(.sending)) \(Int((progress * 100).rounded()))%"
        }
        guard bleManager.isConnected else { return theme.id.text(.lookingForDisplay) }
        if let count = bleManager.sdCacheEntryCount {
            return theme.id.countText(count)
        }
        return theme.id.text(.displayReady)
    }

    private var footerSecondary: String? {
        if let error = spotifyManager.lastError, !error.isEmpty {
            return error
        }
        if let poll = spotifyManager.pollStatus, poll.contains("Rate limited") {
            return "Spotify rate limited \u{2014} retrying soon"
        }
        return nil
    }
}

// MARK: - Header

struct StatusHeader: View {
    let spotifyOn: Bool
    let displayOn: Bool
    let showStatsLink: Bool
    let onOpen: (Panel) -> Void

    @Environment(\.theme) private var theme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .body) private var gearSize: CGFloat = 22

    var body: some View {
        HStack(spacing: 14) {
            StatusDot(on: spotifyOn, name: "Spotify", color: theme.spotify, showsName: showsNames)
            StatusDot(on: displayOn, name: "Display", color: theme.display, showsName: showsNames)
            Spacer(minLength: 8)
            if showStatsLink {
                Button { onOpen(.stats) } label: {
                    Text(theme.id.text(.stats))
                        .themeText(.headerLink)
                        .foregroundStyle(theme.headerLink)
                        .lineLimit(1)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Button { onOpen(.settings) } label: {
                GlyphIcon(glyph: .gear, color: theme.headerLink, size: gearSize)
                    .frame(width: max(44, gearSize + 12), height: max(44, gearSize + 12))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(theme.id.text(.settings))
            .padding(.trailing, -11)
        }
        .padding(.top, 4)
    }

    /// At accessibility text sizes the dot names would crowd out the buttons; the dots keep
    /// their spoken labels either way.
    private var showsNames: Bool {
        !dynamicTypeSize.isAccessibilitySize
    }
}

struct StatusDot: View {
    let on: Bool
    let name: String
    let color: Color
    let showsName: Bool

    @Environment(\.theme) private var theme
    @ScaledMetric(relativeTo: .footnote) private var dotSize: CGFloat = 11

    var body: some View {
        HStack(spacing: 7) {
            StateMarker(filled: on, fillColor: color, ringColor: theme.ringOff, size: dotSize)
            if showsName {
                Text(name)
                    .themeText(.statusLabel)
                    .foregroundStyle(on ? theme.inkSoft : theme.inkFaint)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(name) \(on ? "connected" : "not connected")")
    }
}

// MARK: - Album art

/// The cover as the keychain shows it. While a cover changes it shows the board's own transition
/// frames; send progress lives in the strip below, not on the art.
struct ArtStage: View {
    let image: UIImage?
    /// The previous cover, held while a transition's frames are computed.
    let held: UIImage?
    /// Current frame of a playing board transition.
    let frame: CGImage?
    let side: CGFloat
    let label: String
    let value: String

    @Environment(\.theme) private var theme

    var body: some View {
        ZStack {
            if let frame {
                Image(decorative: frame, scale: 1)
                    .resizable()
                    .interpolation(.medium)
                    .frame(width: side, height: side)
            } else {
                artLayer(held ?? image)
            }
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

/// Drawn stand-in before any cover arrives: the artboards' placeholder art per theme.
struct ArtPlaceholder: View {
    let side: CGFloat
    @Environment(\.theme) private var theme

    var body: some View {
        let k = side / 300
        ZStack(alignment: .topLeading) {
            theme.artSurface
            switch theme.placeholder {
            case .scribbles:
                scribbles(k: k)
            case .filledRings:
                filledRings(k: k)
            case .hairlineRings:
                hairlineRings(k: k)
            }
        }
        .frame(width: side, height: side)
        .accessibilityHidden(true)
    }

    private func scribbles(k: CGFloat) -> some View {
        let p = theme.artPalette
        return ZStack(alignment: .topLeading) {
            ring(112, 104, 52, width: 16, color: Theme.pick(p, 0), seed: 71, k: k)
            ring(196, 150, 70, width: 14, color: Theme.pick(p, 1), seed: 72, k: k)
            scribble([(46, 212), (85, 199), (120, 203), (158, 218), (200, 234), (235, 226), (258, 212)],
                     width: 15, color: Theme.pick(p, 2), seed: 73, k: k)
            scribble([(60, 58), (78, 71), (87, 92), (86, 116)], width: 13, color: Theme.pick(p, 3), seed: 74, k: k)
            scribble([(224, 68), (213, 84), (210, 101), (214, 118)], width: 12, color: Theme.pick(p, 4), seed: 75, k: k)
            scribble([(84, 254), (216, 254)], width: 11, color: Theme.pick(p, 5), seed: 76, k: k)
        }
        .frame(width: side, height: side)
    }

    private func filledRings(k: CGFloat) -> some View {
        let p = theme.artPalette
        return ZStack(alignment: .topLeading) {
            ring(150, 150, 128, width: 18, color: Theme.pick(p, 0), seed: 81, k: k)
            ring(150, 150, 98, width: 14, color: Theme.pick(p, 1), seed: 82, k: k)
            ring(150, 150, 70, width: 10, color: Theme.pick(p, 2), seed: 83, k: k)
            ring(150, 150, 46, width: 7, color: Theme.pick(p, 3), seed: 84, k: k)
            dot(150, 150, 24, color: Theme.pick(p, 4), k: k)
            dot(150, 150, 5, color: theme.background, k: k)
        }
        .frame(width: side, height: side)
    }

    private func hairlineRings(k: CGFloat) -> some View {
        let ink = Theme.pick(theme.artPalette, 0)
        let rust = Theme.pick(theme.artPalette, 1)
        return ZStack(alignment: .topLeading) {
            ring(150, 150, 115, width: 1, color: ink, seed: 91, k: 1 * k)
            ring(150, 150, 86, width: 1, color: ink, seed: 92, k: k)
            ring(150, 150, 58, width: 1, color: ink, seed: 93, k: k)
            ring(150, 150, 29, width: 1, color: ink, seed: 94, k: k)
            dot(150, 150, 7, color: ink, k: k)
            Rectangle()
                .fill(rust)
                .frame(width: 230 * k, height: 2)
                .position(x: 150 * k, y: 205 * k)
        }
        .frame(width: side, height: side)
    }

    private func ring(_ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat, width: CGFloat, color: Color, seed: UInt64, k: CGFloat) -> some View {
        ThemedStroke(
            shape: WobbleEllipse(amplitude: theme.wobble * 2.2, seed: seed),
            color: color,
            lineWidth: max(1, width * k)
        )
        .frame(width: 2 * r * k, height: 2 * r * k)
        .position(x: cx * k, y: cy * k)
    }

    private func dot(_ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat, color: Color, k: CGFloat) -> some View {
        Circle()
            .fill(color)
            .frame(width: 2 * r * k, height: 2 * r * k)
            .position(x: cx * k, y: cy * k)
    }

    private func scribble(_ points: [(CGFloat, CGFloat)], width: CGFloat, color: Color, seed: UInt64, k: CGFloat) -> some View {
        var unit: [CGPoint] = []
        for point in points {
            unit.append(CGPoint(x: point.0 / 300, y: point.1 / 300))
        }
        return ThemedStroke(
            shape: ScribbleShape(unitPoints: unit, amplitude: theme.wobble * 2.2, seed: seed),
            color: color,
            lineWidth: width * k
        )
        .frame(width: side, height: side)
    }
}

// MARK: - Live strip

/// What the strip under the art says. Cached and fresh differ by marker *shape*
/// (filled dot vs hollow ring) as well as colour; sending is a determinate progress line.
enum StripState: Equatable {
    case idle
    case preparing
    case sending(Double)
    case cached(Int)
    case fresh(Int)

    static func derive(
        isTransferring: Bool,
        progress: Double,
        stage: SendStage,
        lastResult: String?,
        lastEntry: TransferLogEntry?
    ) -> StripState {
        if isTransferring {
            return .sending(min(1, max(0, progress)))
        }
        if stage != .idle {
            return .preparing
        }
        if lastResult != nil, let entry = lastEntry {
            return entry.cacheHit ? .cached(entry.totalMs) : .fresh(entry.totalMs)
        }
        return .idle
    }

    var accessibilityText: String {
        switch self {
        case .idle:
            return "Nothing sent yet"
        case .preparing:
            return "Getting the next cover ready"
        case .sending(let progress):
            return "Sending a new cover, \(Int((progress * 100).rounded())) percent"
        case .cached(let ms):
            return "Already on the display, loaded from its memory in \(Self.spoken(ms)) seconds"
        case .fresh(let ms):
            return "New cover sent in \(Self.spoken(ms)) seconds"
        }
    }

    private static func spoken(_ ms: Int) -> String {
        String(format: "%.1f", Double(ms) / 1000.0)
    }
}

struct LiveStrip: View {
    let state: StripState

    @Environment(\.theme) private var theme
    @ScaledMetric(relativeTo: .footnote) private var markerSize: CGFloat = 10

    var body: some View {
        HStack(spacing: 8) {
            marker
                .frame(width: markerSize, height: markerSize)
            line
        }
        .frame(height: max(theme.stripThickness + 8, markerSize))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Display")
        .accessibilityValue(state.accessibilityText)
    }

    @ViewBuilder
    private var marker: some View {
        switch state {
        case .cached:
            StateMarker(filled: true, fillColor: theme.display, ringColor: theme.display, size: markerSize)
        case .fresh:
            StateMarker(filled: false, fillColor: theme.fresh, ringColor: theme.fresh, size: markerSize)
        case .idle, .preparing, .sending:
            Color.clear
        }
    }

    private var line: some View {
        let width = theme.stripThickness
        let shape = WobbleLine(
            amplitude: theme.wobble * 1.2,
            bow: theme.isWobbly ? 2.5 : 0,
            seed: 21,
            inset: width / 2
        )
        // "Preparing" is drawn as a dashed line in a colour with at least 3:1 contrast, since the
        // dashes are the only thing that says so; the plain empty track is decorative.
        let isPreparing = state == .preparing
        let trackDash: [CGFloat] = isPreparing ? [width * 1.2, width * 1.8] : []
        let trackColor = isPreparing ? theme.ringOff : theme.rule
        return ZStack {
            ThemedStroke(shape: shape, color: trackColor, lineWidth: width, dash: trackDash)
            fill(shape: shape, width: width)
        }
    }

    @ViewBuilder
    private func fill(shape: WobbleLine, width: CGFloat) -> some View {
        switch state {
        case .sending(let progress):
            ThemedStroke(shape: shape.trim(from: 0, to: CGFloat(progress)), color: theme.fresh, lineWidth: width)
        case .cached:
            ThemedStroke(shape: shape, color: theme.display, lineWidth: width)
        case .fresh:
            ThemedStroke(shape: shape, color: theme.fresh, lineWidth: width)
        case .idle, .preparing:
            EmptyView()
        }
    }
}

// MARK: - Track info

struct TrackInfo: View {
    let title: String
    let subtitle: String?
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 5) {
            Text(title)
                .themeText(.trackTitle)
                .foregroundStyle(theme.ink)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .frame(maxWidth: .infinity)
            if let subtitle {
                Text(subtitle)
                    .themeText(.trackArtist)
                    .foregroundStyle(theme.inkSoft)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Playback controls

struct PlaybackControls: View {
    @ObservedObject var spotifyManager: SpotifyManager
    @Environment(\.theme) private var theme
    @ScaledMetric(relativeTo: .title3) private var skipSize: CGFloat = 22
    @ScaledMetric(relativeTo: .title) private var playSize: CGFloat = 30

    var body: some View {
        HStack(spacing: 34) {
            control(.previous, size: skipSize, minFrame: 44, color: theme.control, label: "Previous track") {
                Task { await spotifyManager.skipToPrevious() }
            }
            control(
                spotifyManager.isPlaying ? .pause : .play,
                size: playSize,
                minFrame: 56,
                color: theme.controlStrong,
                label: spotifyManager.isPlaying ? "Pause" : "Play"
            ) {
                Task {
                    if spotifyManager.isPlaying {
                        await spotifyManager.pause()
                    } else {
                        await spotifyManager.resume()
                    }
                }
            }
            control(.next, size: skipSize, minFrame: 44, color: theme.control, label: "Next track") {
                Task { await spotifyManager.skipToNext() }
            }
        }
    }

    private func control(
        _ glyph: Glyph,
        size: CGFloat,
        minFrame: CGFloat,
        color: Color,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            GlyphIcon(glyph: glyph, color: color, size: size)
                .frame(width: max(minFrame, size + 16), height: max(minFrame, size + 16))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

// MARK: - Footer

struct NowPlayingFooter: View {
    let primary: String
    let secondary: String?
    /// Live pipeline phase, shown only while "show stats" is on.
    let live: String?
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 4) {
            Text(primary)
                .themeText(.footer)
                .foregroundStyle(theme.headerLink)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .frame(minHeight: 24)
            if let secondary {
                Text(secondary)
                    .themeText(.footnote)
                    .foregroundStyle(theme.inkSoft)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }
            if let live {
                Text(live)
                    .themeText(.mono)
                    .foregroundStyle(theme.inkFaint)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity)
    }
}
