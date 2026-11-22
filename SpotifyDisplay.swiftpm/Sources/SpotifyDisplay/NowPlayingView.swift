import SwiftUI
import UIKit
import PhotosUI

// MARK: - Layout metrics

enum ArtMetrics {
    static let maxSide: CGFloat = 300

    /// Square side for the big cover. Depends only on the safe-area size of the screen (and whether
    /// text is at an accessibility size), never on sibling views, so badges, progress and errors
    /// coming and going cannot resize the art.
    static func side(for size: CGSize, margin: CGFloat, accessibilityText: Bool = false) -> CGFloat {
        let byWidth = size.width - margin * 2
        let byHeight = size.height * (accessibilityText ? 0.34 : 0.46)
        return max(120, min(maxSide, byWidth, byHeight)).rounded(.down)
    }

    /// Nerd mode: the small cover at the top left. 19% of the screen height, kept within 104...130 pt
    /// (about 123 pt on a 4.7" iPhone SE), so the session log gets most of the height.
    static func nerdSide(for size: CGSize) -> CGFloat {
        min(130, max(104, (size.height * 0.19).rounded(.down)))
    }

    /// Text size multiplier for the compact player and the log in nerd mode.
    static let compactTextScale: CGFloat = 0.75

    /// Smallest gap between the header and the big cover; the column is centred in what is left.
    static func topGap(for size: CGSize) -> CGFloat {
        min(28, max(8, size.height * 0.025))
    }

    /// Bottom breathing room: the home indicator already reserves space on Face ID phones;
    /// home-button phones (no bottom inset) need a little more.
    static func bottomPadding(safeAreaBottom: CGFloat) -> CGFloat {
        safeAreaBottom > 0 ? 4 : 14
    }

    /// The quiet stats line under the controls only shows when the screen has room for it.
    static func showsSummary(for size: CGSize, dynamicTypeSize: DynamicTypeSize) -> Bool {
        size.height >= 690 && dynamicTypeSize <= .xxLarge
    }
}

/// Timing for the nerd-mode switch. One spring moves the cover, the track info and the controls;
/// the area under them (log in nerd mode, footer + stats in normal mode) follows a beat later and
/// leaves first, quickly. Reduce Motion: a 0.2 s dip-and-return crossfade, nothing moves.
enum ModeMotion {
    static let spring = Animation.spring(response: 0.42, dampingFraction: 0.86)
    /// How long after the cover starts moving the lower area comes in.
    static let lowerDelay = 0.12
    /// The lower area slides up this far as it fades in.
    static let lowerRise: CGFloat = 14
    static let lowerExit = Animation.easeOut(duration: 0.12)
    /// Nerd -> normal: the log is gone after this long, then the cover grows back.
    static let exitLead = 0.09
    static let reducedHalf = 0.1
}

// MARK: - Now playing

/// Main screen while signed in to Spotify. Covers the Crayon "playing" and "sending" artboards
/// (and their Quiet / Serif counterparts) — sending is a state of this screen, not a new screen.
///
/// Normal mode: the big cover centred with the strip, track info, controls, footer and (on taller
/// screens) a quiet stats line under it. Nerd mode (`@AppStorage("showDebugInfo")`, the header's
/// terminal icon or the Settings toggle): the cover goes small to the top left with the track info and
/// controls to its right, the strip across the width, and the live details + session log below.
///
/// Both modes are one view tree: the single `ArtStage` keeps its identity (so a mirrored transition
/// keeps playing) and only its size and place animate.
struct NowPlayingScreen: View {
    @ObservedObject var bleManager: BLEManager
    @ObservedObject var spotifyManager: SpotifyManager
    let onOpen: (Panel) -> Void

    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// Nerd mode as the person set it. Same key as the Settings toggle, so both stay in sync.
    @AppStorage("showDebugInfo") private var nerdMode = false
    /// Nerd mode as laid out right now. Follows `nerdMode`, sequenced by `applyMode`.
    @State private var layoutNerd = UserDefaults.standard.bool(forKey: "showDebugInfo")
    /// False while the log fades out, before the cover grows back (nerd -> normal).
    @State private var showsLower = true
    /// Reduce Motion crossfade: the player dips to the background and comes back.
    @State private var playerOpacity: Double = 1
    @State private var modeGen = 0
    @Namespace private var playerNS

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

    // Progress line under the cover (see `LiveStrip`).
    @State private var stripRun: StripRun = .idle
    /// Newest transfer-log entry when the current send began; a newer entry at its end = success.
    @State private var stripSinceLogID: UUID?
    /// Highest fill the real BLE progress has reached in this send, so the line never moves back.
    @State private var stripBleFloor: Double = 0
    @State private var stripToken = 0

    var body: some View {
        GeometryReader { geo in
            let bottomPad = ArtMetrics.bottomPadding(safeAreaBottom: geo.safeAreaInsets.bottom)
            let scrolls = dynamicTypeSize.isAccessibilitySize
            VStack(spacing: 0) {
                header
                    .padding(.horizontal, theme.margin)
                    // The last-transition bubble hangs below the header, over the cover.
                    .zIndex(1)
                ScrollIf(enabled: scrolls) {
                    player(size: geo.size, scrolls: scrolls)
                }
                .padding(.bottom, bottomPad)
                .opacity(playerOpacity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
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
            if layoutNerd != nerdMode {
                layoutNerd = nerdMode
            }
        }
        .onChange(of: nerdMode) { on in
            applyMode(on)
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
            stripStageDidChange(stage)
        }
        .onChange(of: bleManager.transferProgress) { progress in
            guard bleManager.isTransferring, case .running = stripRun else { return }
            stripBleFloor = max(stripBleFloor, StripTiming.bleFill(progress))
        }
        .onChange(of: stripFailed) { failed in
            // The error was dismissed or replaced: drop the red line.
            if !failed, case .ended = stripRun {
                stripRun = .idle
            }
        }
    }

    // MARK: Mode switch

    /// Moves the layout to `on`. Toggling again mid-way retargets the springs (they are interruptible)
    /// and `modeGen` drops any step still scheduled by the previous toggle.
    private func applyMode(_ on: Bool) {
        modeGen &+= 1
        let gen = modeGen
        if reduceMotion {
            withAnimation(.easeOut(duration: ModeMotion.reducedHalf)) { playerOpacity = 0 }
            DispatchQueue.main.asyncAfter(deadline: .now() + ModeMotion.reducedHalf) {
                guard gen == modeGen else { return }
                var cut = Transaction()
                cut.disablesAnimations = true
                withTransaction(cut) {
                    layoutNerd = on
                    showsLower = true
                }
                withAnimation(.easeIn(duration: ModeMotion.reducedHalf)) { playerOpacity = 1 }
            }
            return
        }
        playerOpacity = 1
        if on {
            withAnimation(ModeMotion.spring) {
                layoutNerd = true
                showsLower = true
            }
        } else {
            guard layoutNerd else { return }
            // The log leaves first, quickly; then the cover grows back.
            withAnimation(ModeMotion.lowerExit) { showsLower = false }
            DispatchQueue.main.asyncAfter(deadline: .now() + ModeMotion.exitLead) {
                guard gen == modeGen else { return }
                withAnimation(ModeMotion.spring) {
                    layoutNerd = false
                    showsLower = true
                }
            }
        }
    }

    /// Footer / stats (normal) and the log (nerd): in a beat after the cover, out first and fast.
    private var lowerTransition: AnyTransition {
        if reduceMotion { return .opacity }
        return .asymmetric(
            insertion: AnyTransition.opacity
                .combined(with: .offset(y: ModeMotion.lowerRise))
                .animation(ModeMotion.spring.delay(ModeMotion.lowerDelay)),
            removal: AnyTransition.opacity.animation(ModeMotion.lowerExit)
        )
    }

    // MARK: Send state

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

    /// Starts the strip's run when a send begins and resolves it (done / ended) when it stops.
    private func stripStageDidChange(_ stage: SendStage) {
        if stage != .idle {
            if case .running = stripRun { return }
            stripRun = .running(start: Date())
            stripSinceLogID = bleManager.transferLog.last?.id
            stripBleFloor = 0
            stripToken &+= 1
            return
        }
        guard case .running(let start) = stripRun else { return }
        let now = Date()
        let creep = reduceMotion ? StripTiming.creepCeiling : StripTiming.creep(now.timeIntervalSince(start))
        let reached = min(1, max(creep, stripBleFloor))
        let succeeded = bleManager.transferLog.last.map { $0.id != stripSinceLogID } ?? false
        stripRun = succeeded ? .finished(at: now, from: reached) : .ended(at: now, from: reached)
        stripToken &+= 1
        let token = stripToken
        DispatchQueue.main.asyncAfter(deadline: .now() + StripTiming.settleAfter) {
            guard token == stripToken else { return }
            // A failed send stays red (like the board's LED) until the next send or the error clears.
            if case .ended = stripRun, stripFailed { return }
            stripRun = .idle
        }
    }

    /// The last send failed: the Spotify side reports it, or the photo alert is up.
    private var stripFailed: Bool {
        spotifyManager.pollStatus == "Display transfer failed" || photoError != nil
    }

    private var header: some View {
        StatusHeader(
            spotifyOn: spotifyManager.isAuthenticated,
            displayOn: bleManager.isConnected,
            onPhotoPicked: { item in showPhoto(item) },
            extras: HeaderExtras(
                nerdMode: nerdMode,
                onToggleNerdMode: { nerdMode.toggle() }
            ),
            onOpen: onOpen
        )
    }

    // MARK: Photos

    /// Loads the picked photo, crops it square and sends it as a display-only frame.
    private func showPhoto(_ item: PhotosPickerItem) {
        Task {
            guard let data = try? await item.loadTransferable(type: Data.self),
                  let image = UIImage(data: data),
                  let jpeg = PhotoPrep.squareJPEG(from: PhotoPrep.downscaled(image, maxSide: 1400)) else {
                photoError = "Could not read that photo."
                return
            }
            sendPhoto(jpeg)
        }
    }

    /// Same path as an upload: `BLEManager.sendPhoto(jpeg:)`.
    private func sendPhoto(_ jpeg: Data) {
        Task {
            do {
                try await bleManager.sendPhoto(jpeg: jpeg)
            } catch is CancellationError {
            } catch {
                photoError = error.localizedDescription
            }
        }
    }

    /// Takes the uploaded photo off the display and goes back to the current Spotify cover.
    private func backToSpotify() {
        bleManager.endPhotoHold()
        Task { await spotifyManager.requestResync(reason: "photo removed") }
    }

    /// Cover tap: a photo is up -> back to Spotify; otherwise show the last uploaded photo again
    /// (nothing happens when no photo was uploaded since the app was opened).
    private func coverTapped() {
        if bleManager.photoHold {
            backToSpotify()
        } else if let jpeg = bleManager.lastPhotoJPEG {
            sendPhoto(jpeg)
        }
    }

    // MARK: Layout

    /// The whole player in one tree for both modes. Slots never change type, so the cover keeps
    /// its identity; `if` blocks only add or remove the parts around it.
    private func player(size: CGSize, scrolls: Bool) -> some View {
        let nerd = layoutNerd
        let bigSide = ArtMetrics.side(for: size, margin: theme.margin, accessibilityText: scrolls)
        let side = nerd ? ArtMetrics.nerdSide(for: size) : bigSide
        return VStack(spacing: 0) {
            // Normal: flexible space above and below centres the column. Nerd: a small fixed gap.
            Spacer(minLength: nerd ? 6 : ArtMetrics.topGap(for: size))
                .frame(maxHeight: nerd ? 6 : CGFloat.infinity)

            HStack(alignment: .top, spacing: 14) {
                art(side: side)
                if nerd {
                    nerdTrackColumn(side: side)
                        .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, alignment: nerd ? .leading : .center)

            if !nerd {
                strip
                    .frame(width: bigSide)
                    .matchedGeometryEffect(id: "strip", in: playerNS, properties: .position)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 10)
                    .transition(.opacity)
            }

            if !nerd {
                normalTrackBlock(side: bigSide)
                    .transition(.opacity)
                normalLowerBlock(size: size)
                    .transition(lowerTransition)
                Spacer(minLength: 8)
                    .frame(maxHeight: .infinity)
            } else {
                nerdLowerBlock(size: size, scrolls: scrolls)
            }
        }
        .padding(.horizontal, theme.margin)
        .frame(maxWidth: .infinity, maxHeight: scrolls ? nil : CGFloat.infinity, alignment: .top)
    }

    /// Normal mode under the strip: track info, the photo banner and the controls.
    private func normalTrackBlock(side: CGFloat) -> some View {
        VStack(spacing: 0) {
            TrackInfo(title: trackTitle, subtitle: trackSubtitle)
                .frame(width: side)
                .matchedGeometryEffect(id: "track", in: playerNS, properties: .position)
                .padding(.top, 20)
            if bleManager.photoHold {
                photoBanner
                    .frame(width: side)
                    .padding(.top, 12)
            }
            PlaybackControls(spotifyManager: spotifyManager)
                .matchedGeometryEffect(id: "controls", in: playerNS, properties: .position)
                .padding(.top, 18)
        }
    }

    /// Normal mode's footer and, when there is room, a quiet line of this session's stats.
    private func normalLowerBlock(size: CGSize) -> some View {
        VStack(spacing: 0) {
            NowPlayingFooter(primary: footerPrimary, secondary: footerSecondary)
                .padding(.top, 6)
            if ArtMetrics.showsSummary(for: size, dynamicTypeSize: dynamicTypeSize),
               !bleManager.transferLog.isEmpty {
                SessionSummary(entries: bleManager.transferLog)
                    .padding(.top, 18)
                    .transition(.opacity)
            }
        }
    }

    /// Nerd mode, right of the cover: title and artist, the controls right under them, then the strip.
    private func nerdTrackColumn(side: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            TrackInfo(title: trackTitle, subtitle: trackSubtitle, compact: true, leading: true)
                .matchedGeometryEffect(id: "track", in: playerNS, properties: .position)
            PlaybackControls(spotifyManager: spotifyManager, compact: true)
                // The first button's 44 pt frame is wider than its glyph: line the glyph up with the text.
                .padding(.leading, -10)
                .matchedGeometryEffect(id: "controls", in: playerNS, properties: .position)
            strip
                .matchedGeometryEffect(id: "strip", in: playerNS, properties: .position)
                .padding(.top, 2)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, minHeight: side, alignment: .topLeading)
        .environment(\.themeTextScale, ArtMetrics.compactTextScale)
    }

    /// Nerd mode under the cover row: the photo banner, then the live details (fixed) + session log.
    private func nerdLowerBlock(size: CGSize, scrolls: Bool) -> some View {
        VStack(spacing: 0) {
            if bleManager.photoHold {
                photoBanner
            }
            ThemedDivider()
                .padding(.top, 12)
            if showsLower {
                NerdLogView(bleManager: bleManager, spotifyManager: spotifyManager)
                    .frame(height: scrolls ? max(300, size.height * 0.6) : nil)
                    .frame(maxHeight: scrolls ? nil : CGFloat.infinity)
                    .transition(lowerTransition)
            } else {
                Spacer(minLength: 0)
            }
        }
        .environment(\.themeTextScale, ArtMetrics.compactTextScale)
        .transition(lowerTransition)
    }

    /// The cover. Tap: back to Spotify while a photo is up, otherwise the last photo again.
    private func art(side: CGFloat) -> some View {
        let photoUp = bleManager.photoHold
        let canReshow = !photoUp && bleManager.lastPhotoJPEG != nil
        return ArtStage(
            image: shownImage,
            side: side,
            label: artLabel,
            value: artValue,
            event: bleManager.transitionEvent
        )
        .contentShape(Rectangle())
        .onTapGesture { coverTapped() }
        .accessibilityAddTraits(photoUp || canReshow ? .isButton : [])
        .accessibilityHint(
            photoUp ? "Double-tap to go back to Spotify"
                : (canReshow ? "Double-tap to show your last photo on the display" : "")
        )
        .accessibilityAction { coverTapped() }
    }

    private var strip: some View {
        LiveStrip(
            state: stripState,
            run: stripRun,
            stage: bleManager.sendStage,
            bleFloor: stripBleFloor,
            failed: stripFailed
        )
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
        if bleManager.photoHold {
            return "Photo on display"
        }
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
                backToSpotify()
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

/// Wraps `content` in a vertical ScrollView only when `enabled` (accessibility text sizes), so the
/// normal layout keeps its centring and nerd mode's log keeps its own scrolling otherwise.
private struct ScrollIf<Content: View>: View {
    let enabled: Bool
    private let content: () -> Content

    init(enabled: Bool, @ViewBuilder content: @escaping () -> Content) {
        self.enabled = enabled
        self.content = content
    }

    var body: some View {
        if enabled {
            ScrollView(.vertical, showsIndicators: false) {
                content()
            }
        } else {
            content()
        }
    }
}

/// Normal mode's quiet stats line: the last transfer, cache hits and the average fresh send, from
/// this session's transfer log (`BLEManager.transferLog`). The full stats are in Settings.
struct SessionSummary: View {
    let entries: [TransferLogEntry]
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(alignment: .top, spacing: 26) {
            if let last = entries.last {
                cell(
                    value: "\(theme.id.seconds(last.totalMs)) \(theme.id.text(last.cacheHit ? .cachedWord : .freshWord))",
                    label: theme.id.text(.summaryLast)
                )
            }
            if let rate = SessionStats.hitRatePercent(entries) {
                cell(value: "\(rate)%", label: theme.id.text(.summaryHitRate))
            }
            if let avg = SessionStats.averageMs(entries, cacheHit: false) {
                cell(value: theme.id.seconds(avg), label: theme.id.text(.summaryAvgNew))
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    private func cell(value: String, label: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .themeText(.phaseValue)
                .foregroundStyle(theme.inkSoft)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(label)
                .themeText(.statCaption)
                .foregroundStyle(theme.inkFaint)
                .lineLimit(1)
        }
    }
}

// MARK: - Header

/// The signed-in screen's extra header icon: nerd mode. (Transitions live in Settings.)
struct HeaderExtras {
    let nerdMode: Bool
    let onToggleNerdMode: () -> Void
}

/// Dots on the left; icons on the right: [nerd mode] [photo] [settings].
struct StatusHeader: View {
    let spotifyOn: Bool
    let displayOn: Bool
    /// Called with the photo picked from the library; nil hides the icon (signed-out screen).
    var onPhotoPicked: ((PhotosPickerItem) -> Void)? = nil
    /// Nerd-mode icon; nil hides it (signed-out screen).
    var extras: HeaderExtras? = nil
    let onOpen: (Panel) -> Void

    @State private var pickedPhoto: PhotosPickerItem?

    @Environment(\.theme) private var theme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .body) private var gearSize: CGFloat = 22

    private static let iconFont = Font.system(size: 18, weight: .regular)

    var body: some View {
        HStack(spacing: 12) {
            StatusDot(on: spotifyOn, name: "Spotify", color: theme.spotify, showsName: showsNames)
            StatusDot(on: displayOn, name: "Display", color: theme.display, showsName: showsNames)
            Spacer(minLength: 4)
            HStack(spacing: 0) {
                if let extras {
                    nerdButton(extras)
                }
                if let onPhotoPicked {
                    // Pick a library photo and it goes straight to the display.
                    PhotosPicker(selection: $pickedPhoto, matching: .images) {
                        Image(systemName: "photo")
                            .font(Self.iconFont)
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
            }
            .padding(.trailing, -11)
        }
        .padding(.top, 4)
    }

    private func nerdButton(_ extras: HeaderExtras) -> some View {
        let on = extras.nerdMode
        return Button {
            extras.onToggleNerdMode()
        } label: {
            // Both symbols stay in the tree and cross-fade with a little scale (iOS 16 has no symbol
            // content transitions). The highlight disc is a second "on" cue besides the filled symbol.
            let pop: CGFloat = reduceMotion ? 1 : 0.6
            ZStack {
                Circle()
                    .fill(theme.rule)
                    .frame(width: 36, height: 36)
                    .scaleEffect(on ? 1 : (reduceMotion ? 1 : 0.5))
                    .opacity(on ? 1 : 0)
                Image(systemName: "terminal")
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(theme.headerLink)
                    .scaleEffect(on ? pop : 1)
                    .opacity(on ? 0 : 1)
                Image(systemName: "terminal.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(theme.ink)
                    .scaleEffect(on ? 1 : pop)
                    .opacity(on ? 1 : 0)
            }
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
            .animation(
                reduceMotion ? .easeInOut(duration: 0.15) : .spring(response: 0.3, dampingFraction: 0.7),
                value: on
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Nerd mode, live stats")
        .accessibilityValue(on ? "On" : "Off")
        .accessibilityAddTraits(on ? .isSelected : [])
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
                    // Four header icons leave little room on a 4.7" phone (Serif's tracked caps).
                    .minimumScaleFactor(0.7)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(name) \(on ? "connected" : "not connected")")
    }
}

// MARK: - Album art

// `ArtStage` (the cover and its transition playback) lives in ArtStage.swift.

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

/// What the strip says for VoiceOver, the footer and its resting marker. Cached and fresh differ by
/// marker *shape* (filled dot vs hollow ring) as well as colour.
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

/// One send as the progress line draws it over time. Kept by `NowPlayingScreen` from `sendStage`
/// and the transfer log; `LiveStrip` turns it into fill, colour and fade.
enum StripRun: Equatable {
    /// Nothing in flight: empty track plus the last result's marker.
    case idle
    /// A send is in progress since `start` (cache check, download, dither, BLE).
    case running(start: Date)
    /// The send succeeded at `at`; the fill was at `from`. Animates to full green, then fades.
    case finished(at: Date, from: Double)
    /// The send stopped without a new log entry: skipped, cancelled or failed.
    case ended(at: Date, from: Double)
}

/// Fill timing. While the phone works the fill creeps up on its own with an ease-out curve that
/// approaches `creepCeiling` but never reaches it; real BLE progress fills the rest.
enum StripTiming {
    static let creepCeiling = 0.6
    static let creepTau = 0.6
    /// Time to run from the current fill to 100% on success.
    static let finishFill = 0.25
    /// Full green is held this long before it fades, like the LED's flash.
    static let hold = 0.9
    static let fade = 0.8
    /// A skipped / cancelled send fades out this fast.
    static let endFade = 0.4
    /// When `NowPlayingScreen` drops a finished run back to idle (stops the timeline).
    static var settleAfter: Double { finishFill + hold + fade + 0.15 }

    static func creep(_ elapsed: TimeInterval) -> Double {
        creepCeiling * (1 - exp(-max(0, elapsed) / creepTau))
    }

    static func bleFill(_ progress: Double) -> Double {
        creepCeiling + (1 - creepCeiling) * min(1, max(0, progress))
    }
}

/// The board's status-LED colours (src/main.cpp): blue = cache check / drawing a cached cover,
/// orange = a new cover on its way, green = done, red = error. On the white themes the LED's pure
/// green is darkened to keep 3:1 against the page; the hue stays the LED's.
enum StripColors {
    static func check(_ theme: Theme) -> Color {
        theme.colorScheme == .dark ? Color(hex: 0x3D7BFF) : Color(hex: 0x0050FF)
    }

    static func fresh(_ theme: Theme) -> Color {
        Color(hex: 0xFF5A00)
    }

    static func done(_ theme: Theme) -> Color {
        theme.colorScheme == .dark ? Color(hex: 0x00FF28) : Color(hex: 0x00A01E)
    }

    static func error(_ theme: Theme) -> Color {
        Color(hex: 0xFF0000)
    }
}

struct LiveStrip: View {
    let state: StripState
    var run: StripRun = .idle
    var stage: SendStage = .idle
    /// Highest fill real BLE progress has reached in this send.
    var bleFloor: Double = 0
    /// The send that just ended failed: the line turns red and stays.
    var failed = false

    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .footnote) private var markerSize: CGFloat = 10

    private enum Marker {
        case none, cached, fresh, failed
    }

    private struct Look {
        var fill: Double
        var color: Color
        var opacity: Double
        /// The unfilled part is dashed during the cache check (a non-colour cue for "checking").
        var dashedTrack: Bool
        var marker: Marker
    }

    var body: some View {
        // Ticks only while something moves; Reduce Motion steps 4x a second with no creep.
        TimelineView(.animation(minimumInterval: reduceMotion ? 0.25 : nil, paused: !isAnimating)) { context in
            let look = appearance(at: context.date)
            // Only a failure gets a marker (the red x); the cached / fresh dot was removed by request.
            HStack(spacing: 8) {
                if look.marker == .failed {
                    marker(look.marker)
                        .frame(width: markerSize, height: markerSize)
                }
                line(look)
            }
        }
        .frame(height: max(theme.stripThickness + 8, markerSize))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Display")
        .accessibilityValue(accessibilityText)
    }

    private var isAnimating: Bool {
        switch run {
        case .idle: return false
        case .running, .finished: return true
        case .ended: return !failed
        }
    }

    private var accessibilityText: String {
        if case .ended = run, failed {
            return "Sending the cover failed"
        }
        return state.accessibilityText
    }

    /// Marker shown when no send is moving: what the last one was.
    private var restingMarker: Marker {
        switch state {
        case .cached: return .cached
        case .fresh: return .fresh
        case .idle, .preparing, .sending: return .none
        }
    }

    private func appearance(at now: Date) -> Look {
        switch run {
        case .idle:
            return Look(fill: 0, color: .clear, opacity: 0, dashedTrack: false, marker: restingMarker)

        case .running(let start):
            let creep: Double
            if reduceMotion {
                creep = stage == .checking ? StripTiming.creepCeiling / 2 : StripTiming.creepCeiling
            } else {
                creep = StripTiming.creep(now.timeIntervalSince(start))
            }
            let checking = stage == .checking
            return Look(
                fill: min(1, max(creep, bleFloor)),
                color: checking ? StripColors.check(theme) : StripColors.fresh(theme),
                opacity: 1,
                dashedTrack: checking,
                marker: .none
            )

        case .finished(let at, let from):
            let dt = now.timeIntervalSince(at)
            let fill: Double
            if reduceMotion {
                fill = 1
            } else {
                let k = min(1, max(0, dt / StripTiming.finishFill))
                fill = from + (1 - from) * (1 - pow(1 - k, 3))
            }
            let fadeStart = StripTiming.finishFill + StripTiming.hold
            let opacity: Double
            if dt <= fadeStart {
                opacity = 1
            } else if reduceMotion {
                opacity = 0
            } else {
                opacity = max(0, 1 - (dt - fadeStart) / StripTiming.fade)
            }
            return Look(fill: fill, color: StripColors.done(theme), opacity: opacity, dashedTrack: false, marker: restingMarker)

        case .ended(let at, let from):
            if failed {
                return Look(fill: 1, color: StripColors.error(theme), opacity: 1, dashedTrack: false, marker: .failed)
            }
            let dt = now.timeIntervalSince(at)
            let opacity = reduceMotion ? 0 : max(0, 1 - dt / StripTiming.endFade)
            return Look(fill: from, color: StripColors.fresh(theme), opacity: opacity, dashedTrack: false, marker: .none)
        }
    }

    @ViewBuilder
    private func marker(_ marker: Marker) -> some View {
        switch marker {
        case .cached:
            StateMarker(filled: true, fillColor: StripColors.check(theme), ringColor: StripColors.check(theme), size: markerSize)
        case .fresh:
            StateMarker(filled: false, fillColor: StripColors.fresh(theme), ringColor: StripColors.fresh(theme), size: markerSize)
        case .failed:
            Image(systemName: "xmark")
                .font(.system(size: markerSize, weight: .bold))
                .foregroundStyle(StripColors.error(theme))
        case .none:
            Color.clear
        }
    }

    private func line(_ look: Look) -> some View {
        let width = theme.stripThickness
        let shape = WobbleLine(
            amplitude: theme.wobble * 1.2,
            bow: theme.isWobbly ? 2.5 : 0,
            seed: 21,
            inset: width / 2
        )
        // The dashed track is drawn in a colour with at least 3:1 contrast, since the dashes carry
        // meaning; the plain empty track is decorative.
        let trackDash: [CGFloat] = look.dashedTrack ? [width * 1.2, width * 1.8] : []
        let trackColor = look.dashedTrack ? theme.ringOff : theme.rule
        let showsFill = look.fill > 0.001 && look.opacity > 0.001
        return ZStack {
            ThemedStroke(shape: shape, color: trackColor, lineWidth: width, dash: trackDash)
            if showsFill {
                ThemedStroke(shape: shape.trim(from: 0, to: CGFloat(look.fill)), color: look.color, lineWidth: width)
                    .opacity(look.opacity)
            }
        }
    }
}

// MARK: - Track info

struct TrackInfo: View {
    let title: String
    let subtitle: String?
    /// Nerd mode: tighter (the text itself is scaled down by `themeTextScale`).
    var compact = false
    /// Nerd mode's player row: left-aligned next to the cover; the title may take two lines.
    var leading = false
    @Environment(\.theme) private var theme

    var body: some View {
        let textAlign: TextAlignment = leading ? .leading : .center
        let frameAlign: Alignment = leading ? .leading : .center
        VStack(alignment: leading ? .leading : .center, spacing: compact ? 2 : 5) {
            Text(title)
                .themeText(.trackTitle)
                .foregroundStyle(theme.ink)
                .multilineTextAlignment(textAlign)
                .lineLimit(compact && !leading ? 1 : 2)
                .frame(maxWidth: .infinity, alignment: frameAlign)
            if let subtitle {
                Text(subtitle)
                    .themeText(.trackArtist)
                    .foregroundStyle(theme.inkSoft)
                    .multilineTextAlignment(textAlign)
                    .lineLimit(compact ? 1 : 2)
                    .frame(maxWidth: .infinity, alignment: frameAlign)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Playback controls

struct PlaybackControls: View {
    @ObservedObject var spotifyManager: SpotifyManager
    /// Nerd mode: smaller glyphs, every button still a 44pt target.
    var compact = false
    @Environment(\.theme) private var theme
    @ScaledMetric(relativeTo: .title3) private var skipSize: CGFloat = 22
    @ScaledMetric(relativeTo: .title) private var playSize: CGFloat = 30

    var body: some View {
        let skip = compact ? skipSize * 0.8 : skipSize
        let play = compact ? playSize * 0.75 : playSize
        // Compact sits beside the nerd-mode cover, so its 44 pt buttons nearly touch.
        HStack(spacing: compact ? 8 : 34) {
            control(.previous, size: skip, minFrame: 44, color: theme.control, label: "Previous track") {
                Task { await spotifyManager.skipToPrevious() }
            }
            control(
                spotifyManager.isPlaying ? .pause : .play,
                size: play,
                minFrame: compact ? 44 : 56,
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
            control(.next, size: skip, minFrame: 44, color: theme.control, label: "Next track") {
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
        }
        .frame(maxWidth: .infinity)
    }
}
