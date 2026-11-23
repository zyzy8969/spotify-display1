import SwiftUI
import UIKit
import PhotosUI

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
/// (and their Quiet / Keyring counterparts) — sending is a state of this screen, not a new screen.
struct NowPlayingScreen: View {
    @ObservedObject var bleManager: BLEManager
    @ObservedObject var spotifyManager: SpotifyManager
    let showStatsLink: Bool
    let onOpen: (Panel) -> Void

    @Environment(\.theme) private var theme
    /// Which page of the main screen is showing. Stats pages exist only while "show stats" is on.
    @State private var tab: MainTab = .nowPlaying
    @State private var photoError: String?
    /// What the keychain shows right now, decoded once per change instead of on every render.
    @State private var shownImage: UIImage?
    /// A fresh send's new cover, held back until the board confirms it. The firmware draws a new
    /// frame only when it is whole (with a transition, just before its ACK) and leaves the old
    /// picture up if the send fails, so the app does the same.
    @State private var pendingImage: UIImage?
    /// Newest transfer-log entry when the pending send began; a newer non-cache entry at the end
    /// of the send means it succeeded.
    @State private var pendingSinceLogID: UUID?

    var body: some View {
        GeometryReader { geo in
            let side = ArtMetrics.side(for: geo.size, margin: theme.margin)
            let topGap = ArtMetrics.topGap(for: geo.size)
            let bottomPad = ArtMetrics.bottomPadding(safeAreaBottom: geo.safeAreaInsets.bottom)
            Group {
                if activeTab == .nowPlaying {
                    FitOrScroll {
                        column(side: side, topGap: topGap, bottomPad: bottomPad)
                    }
                } else {
                    statsPage(bottomPad: bottomPad)
                }
            }
            // Swipe left/right between the pages. Vertical drags still scroll.
            .simultaneousGesture(
                DragGesture(minimumDistance: 40).onEnded { drag in
                    guard showStatsLink else { return }
                    let dx = drag.translation.width
                    let dy = drag.translation.height
                    guard abs(dx) > abs(dy) * 1.5 else { return }
                    withAnimation(.easeOut(duration: 0.2)) {
                        tab = dx < 0 ? activeTab.next : activeTab.previous
                    }
                }
            )
        }
        .alert("Photo", isPresented: Binding(
            get: { photoError != nil },
            set: { if !$0 { photoError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(photoError ?? "")
        }
        .onAppear {
            shownImage = Self.decode(bleManager.currentAlbumArt)
        }
        .onChange(of: bleManager.currentAlbumArt) { newData in
            // During a fresh send the stage handler below picks the art up; anything else
            // (a confirmed cache hit, the paused preview) is already what the display shows.
            guard bleManager.sendStage != .preparingFresh else { return }
            shownImage = Self.decode(newData)
            pendingImage = nil
        }
        // `sendStage` returns to idle on every exit from processTrack (success, error, skip).
        .onChange(of: bleManager.sendStage) { stage in
            stageDidChange(stage)
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
                shownImage = pending
            }
            pendingImage = nil
            pendingSinceLogID = nil
        case .checking:
            break
        }
    }

    /// Stats off: always Now Playing, whatever page was last open.
    private var activeTab: MainTab { showStatsLink ? tab : .nowPlaying }

    private var header: some View {
        StatusHeader(
            spotifyOn: spotifyManager.isAuthenticated,
            displayOn: bleManager.isConnected,
            onPhotoPicked: { item in showPhoto(item) },
            onOpen: onOpen
        )
    }

    /// Loads the picked photo, crops it square and sends it as a display-only frame.
    private func showPhoto(_ item: PhotosPickerItem) {
        Task {
            guard let data = try? await item.loadTransferable(type: Data.self),
                  let image = UIImage(data: data),
                  let jpeg = PhotoPrep.squareJPEG(from: PhotoPrep.downscaled(image, maxSide: 1400)) else {
                photoError = "Could not read that photo."
                return
            }
            do {
                try await bleManager.sendPhoto(jpeg: jpeg)
            } catch is CancellationError {
            } catch {
                photoError = error.localizedDescription
            }
        }
    }

    /// General and Live pages: same header and tab bar, then scrolling content instead of the cover.
    private func statsPage(bottomPad: CGFloat) -> some View {
        VStack(spacing: 0) {
            header
            MainTabBar(selection: $tab)
                .padding(.top, 4)
            ScrollView(.vertical, showsIndicators: false) {
                Group {
                    if activeTab == .general {
                        GeneralStatsView(bleManager: bleManager, spotifyManager: spotifyManager)
                    } else {
                        LiveView(bleManager: bleManager, spotifyManager: spotifyManager, onOpen: onOpen)
                    }
                }
                .padding(.top, 18)
                .padding(.bottom, 24)
            }
        }
        .padding(.horizontal, theme.margin)
        .padding(.bottom, bottomPad)
        .frame(maxWidth: .infinity)
    }

    private func column(side: CGFloat, topGap: CGFloat, bottomPad: CGFloat) -> some View {
        VStack(spacing: 0) {
            header
            if showStatsLink {
                MainTabBar(selection: $tab)
                    .padding(.top, 4)
            }
            Color.clear.frame(height: topGap)
            ArtStage(
                image: shownImage,
                side: side,
                label: artLabel,
                value: artValue,
                event: bleManager.transitionEvent
            )
            LiveStrip(state: stripState)
                .frame(width: side)
                .padding(.top, 10)
            TrackInfo(title: trackTitle, subtitle: trackSubtitle)
                .frame(width: side)
                .padding(.top, 20)
            if bleManager.photoHold {
                photoBanner
                    .frame(width: side)
                    .padding(.top, 12)
            }
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

    /// Shown while a photo the person uploaded is on the display (Spotify sends are paused).
    private var photoBanner: some View {
        HStack(spacing: 10) {
            Text("Photo on display")
                .themeText(.footnote)
                .foregroundStyle(theme.inkSoft)
            Spacer(minLength: 8)
            Button {
                bleManager.endPhotoHold()
                Task { await spotifyManager.requestResync(reason: "photo removed") }
            } label: {
                Text("Back to Spotify")
                    .themeText(.rowValue)
                    .foregroundStyle(theme.ink)
                    .underline()
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
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

/// Which page of the signed-in main screen is showing.
enum MainTab: String, CaseIterable, Identifiable {
    case nowPlaying, general, live

    var id: String { rawValue }

    var title: String {
        switch self {
        case .nowPlaying: return "Now Playing"
        case .general: return "General"
        case .live: return "Live"
        }
    }

    var next: MainTab {
        let all = MainTab.allCases
        let i = all.firstIndex(of: self) ?? 0
        return all[min(all.count - 1, i + 1)]
    }

    var previous: MainTab {
        let all = MainTab.allCases
        let i = all.firstIndex(of: self) ?? 0
        return all[max(0, i - 1)]
    }
}

/// Segmented switch under the header. Selected = filled dot, others hollow ring, so the state never
/// relies on colour alone.
struct MainTabBar: View {
    @Binding var selection: MainTab
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 0) {
            ForEach(MainTab.allCases) { item in
                Button {
                    selection = item
                } label: {
                    HStack(spacing: 6) {
                        StateMarker(filled: selection == item, fillColor: theme.display, ringColor: theme.ringOff, size: 9)
                        Text(item.title)
                            .themeText(.statusLabel)
                            .foregroundStyle(selection == item ? theme.ink : theme.inkFaint)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selection == item ? .isSelected : [])
            }
        }
    }
}

struct StatusHeader: View {
    let spotifyOn: Bool
    let displayOn: Bool
    /// Called with the photo picked from the library; nil hides the icon (signed-out screen).
    var onPhotoPicked: ((PhotosPickerItem) -> Void)? = nil
    let onOpen: (Panel) -> Void

    @State private var pickedPhoto: PhotosPickerItem?

    @Environment(\.theme) private var theme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .body) private var gearSize: CGFloat = 22

    var body: some View {
        HStack(spacing: 14) {
            StatusDot(on: spotifyOn, name: "Spotify", color: theme.spotify, showsName: showsNames)
            StatusDot(on: displayOn, name: "Display", color: theme.display, showsName: showsNames)
            Spacer(minLength: 8)
            if let onPhotoPicked {
                // Small corner icon: pick a library photo and it goes straight to the display.
                PhotosPicker(selection: $pickedPhoto, matching: .images) {
                    Image(systemName: "photo")
                        .font(.system(size: 18, weight: .regular))
                        .foregroundStyle(theme.headerLink)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Show a photo on the display")
                .onChange(of: pickedPhoto) { item in
                    guard let item else { return }
                    pickedPhoto = nil
                    onPhotoPicked(item)
                }
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
        Group {
            if let housing = theme.housing {
                KeychainHousing(housing: housing, side: side) { framedArt }
            } else {
                framedArt
            }
        }
        .onAppear { previous = image }
        .onChange(of: imageID) { _ in imageDidChange() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(value)
        .accessibilityAddTraits(.isImage)
    }

    /// Side of the picture itself: the full slot, or the keychain's screen inside its drawing.
    private var artSide: CGFloat {
        theme.housing == nil ? side : KeychainMetrics.screenSide(for: side)
    }

    /// The cover in its theme frame (surface, corners, border, shadow, Crayon's doodle).
    private var framedArt: some View {
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
        .frame(width: artSide, height: artSide)
        .background(theme.artSurface)
        .clipShape(RoundedRectangle(cornerRadius: theme.artCornerRadius, style: .continuous))
        .overlay(border)
        .shadow(color: theme.artShadowColor, radius: theme.artShadowRadius, x: 0, y: theme.artShadowY)
        .background(frameDoodle)
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
                .frame(width: artSide, height: artSide)
                .clipped()
        } else {
            ArtPlaceholder(side: artSide)
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

/// Keyring: the keychain drawn around its screen, so what you see is what is on your keys.
/// The screen is square like the board's 240x240 panel; the case is a rounded slab with a
/// slightly deeper bottom bezel, hung from a key ring. Purely decorative: the art's own
/// accessibility label describes the picture.
/// Sizes for `KeychainHousing`, outside the generic view so `ArtStage` can ask for them.
enum KeychainMetrics {
    /// Case width as a share of the art slot.
    static let caseShare: CGFloat = 0.92
    /// Side bezel as a share of the case width.
    static let bezelShare: CGFloat = 0.085

    static func screenSide(for side: CGFloat) -> CGFloat {
        let caseWidth = side * caseShare
        return (caseWidth - 2 * caseWidth * bezelShare).rounded(.down)
    }
}

struct KeychainHousing<Screen: View>: View {
    let housing: Housing
    /// Width of the art slot the layout reserved; the case fills most of it.
    let side: CGFloat
    @ViewBuilder let screen: () -> Screen

    var body: some View {
        let caseWidth = side * KeychainMetrics.caseShare
        let bezel = caseWidth * KeychainMetrics.bezelShare
        let screenSide = KeychainMetrics.screenSide(for: side)
        let caseHeight = screenSide + bezel + bezel * 1.7
        let ringSize = side * 0.15
        let ringWidth = max(3, side * 0.018)
        let caseShape = RoundedRectangle(cornerRadius: caseWidth * 0.11, style: .continuous)

        VStack(spacing: 0) {
            Circle()
                .stroke(housing.ring, lineWidth: ringWidth)
                .frame(width: ringSize, height: ringSize)
            Capsule()
                .fill(housing.ring)
                .frame(width: ringSize * 0.3, height: ringSize * 0.5)
                .padding(.top, -ringWidth)
                .padding(.bottom, -ringSize * 0.12)
                .zIndex(-1)
            screen()
                .padding(.top, bezel)
                .frame(width: caseWidth, height: caseHeight, alignment: .top)
                .background(caseShape.fill(housing.body))
                .overlay(caseShape.strokeBorder(housing.edge, lineWidth: 1.5))
                .shadow(color: housing.body.opacity(0.22), radius: 14, x: 0, y: 10)
        }
        .frame(width: side)
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
