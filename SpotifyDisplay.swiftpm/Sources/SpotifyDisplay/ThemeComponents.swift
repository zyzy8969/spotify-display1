import SwiftUI
import UIKit

/// Day <-> night (and theme) changes fade instead of snapping (owner, 2026-11-23: "dark mode should
/// fade into black"). `preferredColorScheme` can't be animated, so this snapshots the whole window
/// (open sheets included), applies `change` underneath, and fades the snapshot out. A plain fade is
/// fine under Reduce Motion.
enum ThemeFade {
    @MainActor static func perform(duration: TimeInterval = 0.45, _ change: () -> Void) {
        guard let window = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .flatMap(\.windows)
                .first(where: \.isKeyWindow),
              let snapshot = window.snapshotView(afterScreenUpdates: false) else {
            change()
            return
        }
        snapshot.frame = window.bounds
        snapshot.isUserInteractionEnabled = false
        window.addSubview(snapshot)
        change()
        UIView.animate(withDuration: duration, delay: 0.03, options: [.curveEaseInOut]) {
            snapshot.alpha = 0
        } completion: { _ in
            snapshot.removeFromSuperview()
        }
    }
}

/// Which sheet is open over the main screen.
enum Panel: String, Identifiable {
    case settings
    case transitions

    var id: String { rawValue }
}

/// Lays `content` out to fill the screen (so its Spacers spread controls apart), and only falls
/// back to scrolling when it cannot fit, e.g. at the largest accessibility text sizes or on a
/// short screen in landscape. Content heights here change only with the text-size setting, so
/// the choice does not flip during a transfer.
struct FitOrScroll<Content: View>: View {
    private let content: () -> Content

    init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }

    var body: some View {
        ViewThatFits(in: .vertical) {
            content()
            ScrollView(.vertical, showsIndicators: false) {
                content()
            }
        }
    }
}

/// Top of a sheet: a 44pt close control (swipe-down also dismisses) and the sheet's title.
struct SheetHeader: View {
    let title: String
    let onClose: () -> Void
    @Environment(\.theme) private var theme
    @ScaledMetric(relativeTo: .body) private var iconSize: CGFloat = 22

    var body: some View {
        HStack(spacing: 2) {
            Button(action: onClose) {
                GlyphIcon(glyph: .chevronDown, color: theme.backTint, size: iconSize)
                    .frame(width: max(44, iconSize + 12), height: max(44, iconSize + 12))
                    .contentShape(Rectangle())
            }
            .buttonStyle(ThemedPressStyle())
            .accessibilityLabel(theme.id.text(.close))
            .padding(.leading, -11)

            Text(title)
                .themeText(.sheetTitle)
                .foregroundStyle(theme.ink)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
        }
        .padding(.top, 12)
    }
}

// MARK: - Theme motion

/// Swaps `content` with the theme's own motion whenever `key` changes (song title, play/pause glyph).
/// Crayon pops in with a little tilt, Quiet blurs into focus, Keyring rolls up like a flip display.
/// Exits are shorter than entrances. Reduce Motion: a plain crossfade for every theme.
struct ThemedChange<Content: View>: View {
    let key: String
    @ViewBuilder let content: () -> Content

    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            content()
                .id(key)
                .transition(transition)
        }
        // Only the ticker needs a window: its words slide in from below the line they sit on.
        .clipShape(Rectangle().inset(by: rolls ? 0 : -400))
        .animation(animation, value: key)
    }

    private var rolls: Bool { theme.motion == .ticker && !reduceMotion }

    private var transition: AnyTransition {
        if reduceMotion { return .opacity }
        switch theme.motion {
        case .bouncy:
            return .asymmetric(
                insertion: .modifier(active: PopEffect(scale: 0.78, angle: -7, opacity: 0),
                                     identity: PopEffect(scale: 1, angle: 0, opacity: 1)),
                removal: .opacity.animation(.easeOut(duration: 0.1))
            )
        case .soft:
            return .asymmetric(
                insertion: .modifier(active: BlurFadeEffect(radius: 12, opacity: 0),
                                     identity: BlurFadeEffect(radius: 0, opacity: 1)),
                removal: .modifier(active: BlurFadeEffect(radius: 8, opacity: 0),
                                   identity: BlurFadeEffect(radius: 0, opacity: 1))
                    .animation(.easeOut(duration: 0.18))
            )
        case .ticker:
            return .asymmetric(
                insertion: .move(edge: .bottom).combined(with: .opacity),
                removal: .move(edge: .top).combined(with: .opacity).animation(.easeIn(duration: 0.16))
            )
        }
    }

    private var animation: Animation {
        if reduceMotion { return .easeInOut(duration: 0.2) }
        switch theme.motion {
        case .bouncy: return .spring(response: 0.42, dampingFraction: 0.58)
        case .soft: return .easeOut(duration: 0.45)
        case .ticker: return .timingCurve(0.16, 1, 0.3, 1, duration: 0.36)
        }
    }
}

private struct PopEffect: ViewModifier {
    let scale: CGFloat
    let angle: Double
    let opacity: Double

    func body(content: Content) -> some View {
        content
            .scaleEffect(scale)
            .rotationEffect(.degrees(angle))
            .opacity(opacity)
    }
}

private struct BlurFadeEffect: ViewModifier {
    let radius: CGFloat
    let opacity: Double

    func body(content: Content) -> some View {
        content
            .blur(radius: radius)
            .opacity(opacity)
    }
}

/// Press feedback in the theme's hand: Crayon squishes and wiggles back, Quiet only dims, Keyring
/// clicks down like a physical button. The hit area never moves (the label does). Reduce Motion: dims.
struct ThemedPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        PressBody(label: configuration.label, isPressed: configuration.isPressed)
    }

    private struct PressBody: View {
        let label: ButtonStyleConfiguration.Label
        let isPressed: Bool
        @Environment(\.theme) private var theme
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            let p = isPressed
            let motion: ThemeMotion? = reduceMotion ? nil : theme.motion
            label
                .scaleEffect(p ? (motion == .bouncy ? 0.84 : (motion == .ticker ? 0.96 : 1)) : 1)
                .rotationEffect(.degrees(p && motion == .bouncy ? -5 : 0))
                .offset(y: p && motion == .ticker ? 2 : 0)
                .opacity(p && (motion == .soft || motion == nil) ? 0.42 : 1)
                .animation(animation(pressed: p, motion: motion), value: p)
        }

        private func animation(pressed: Bool, motion: ThemeMotion?) -> Animation {
            switch motion {
            case .bouncy:
                // Squish quickly, spring back with a wobble.
                return pressed ? .easeOut(duration: 0.08) : .spring(response: 0.32, dampingFraction: 0.45)
            case .ticker:
                return .easeOut(duration: pressed ? 0.05 : 0.12)
            case .soft, nil:
                return .easeOut(duration: pressed ? 0.08 : 0.25)
            }
        }
    }
}

// MARK: - Quiet: the cover lights the room

/// Quiet's signature: a soft glow of the current cover spreading from behind it, as if the picture
/// lit a dark room. It is masked to a pool around the cover so the header and the words under the
/// cover stay on the plain page (their contrast never depends on the cover). Cheap: a tiny image,
/// blurred, then scaled up; it only changes when the cover does (a slow crossfade).
/// Reduce Transparency: off.
struct AmbientArt: View {
    let image: UIImage?
    /// Centre of the glow, as a fraction of the screen (where the big cover sits).
    var center: UnitPoint = UnitPoint(x: 0.5, y: 0.36)

    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        GeometryReader { geo in
            let w = max(1, geo.size.width)
            let h = max(1, geo.size.height)
            let small = CGSize(width: 48, height: 48 * h / w)
            ZStack {
                if let image, !reduceTransparency {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: small.width, height: small.height)
                        .clipped()
                        .blur(radius: 6, opaque: true)
                        .scaleEffect(w / small.width, anchor: .topLeading)
                        .frame(width: w, height: h, alignment: .topLeading)
                        .id(ObjectIdentifier(image))
                        .transition(.opacity)
                }
            }
            .frame(width: w, height: h)
            .opacity(theme.colorScheme == .dark ? 0.5 : 0.32)
            .mask(
                RadialGradient(
                    colors: [.black, .black.opacity(0.55), .clear],
                    center: center,
                    startRadius: 0,
                    endRadius: w * 0.72
                )
            )
            .animation(.easeInOut(duration: 0.9), value: image.map { ObjectIdentifier($0) })
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - Keyring: the keychain is the picture

/// Sizes for `KeychainHousing`, outside the generic view so callers can ask for them.
enum KeychainMetrics {
    /// Case width as a share of the art slot.
    static let caseShare: CGFloat = 0.94
    /// Side bezel as a share of the case width.
    static let bezelShare: CGFloat = 0.065
    /// Keyring's slot is this share of the bare cover's, so case + ring take about the same height.
    static let slotShare: CGFloat = 0.9

    static func caseWidth(for side: CGFloat) -> CGFloat { side * caseShare }

    static func screenSide(for side: CGFloat) -> CGFloat {
        let caseWidth = caseWidth(for: side)
        return (caseWidth - 2 * caseWidth * bezelShare).rounded(.down)
    }
}

/// Keyring's signature: the keychain drawn around its screen, so what you see is what is on your keys.
/// A square screen like the board's 240x240 panel, a deeper chin with the link light, a key ring on
/// top. The light is lit in the signal colour while the keychain is linked (a hollow ring when not);
/// the header's Display dot says the same in words, so the drawing itself is hidden from VoiceOver.
struct KeychainHousing<Screen: View>: View {
    let housing: Housing
    /// Width of the art slot; the case fills most of it.
    let side: CGFloat
    let linked: Bool
    /// Drawn behind the case (the peeking photo card).
    var behindCase: AnyView? = nil
    @ViewBuilder let screen: () -> Screen

    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let caseWidth = KeychainMetrics.caseWidth(for: side)
        let bezel = caseWidth * KeychainMetrics.bezelShare
        let screenSide = KeychainMetrics.screenSide(for: side)
        let chin = bezel * 1.9
        let caseHeight = screenSide + bezel + chin
        let ringSize = side * 0.13
        let ringWidth = max(3, side * 0.017)
        let led = max(6, bezel * 0.42)
        let caseShape = RoundedRectangle(cornerRadius: caseWidth * 0.1, style: .continuous)

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
            ZStack(alignment: .top) {
                if let behindCase {
                    behindCase.accessibilityHidden(true)
                }
                VStack(spacing: 0) {
                    screen()
                        .padding(.top, bezel)
                    HStack {
                        Spacer(minLength: 0)
                        linkLight(size: led)
                    }
                    .frame(height: chin)
                    .padding(.horizontal, bezel * 1.4)
                }
                .frame(width: caseWidth, height: caseHeight, alignment: .top)
                .background(caseShape.fill(housing.body))
                .overlay(caseShape.strokeBorder(housing.edge, lineWidth: 1.5))
                .shadow(color: .black.opacity(theme.colorScheme == .dark ? 0.5 : 0.2), radius: 14, x: 0, y: 10)
            }
        }
        .frame(width: side)
    }

    private func linkLight(size: CGFloat) -> some View {
        ZStack {
            Circle()
                .stroke(housing.ring, lineWidth: 1.5)
                .opacity(linked ? 0 : 1)
            Circle()
                .fill(theme.display)
                .shadow(color: theme.display.opacity(0.8), radius: size * 0.6)
                .opacity(linked ? 1 : 0)
                .scaleEffect(linked || reduceMotion ? 1 : 0.4)
        }
        .frame(width: size, height: size)
        .animation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.35, dampingFraction: 0.6), value: linked)
        .accessibilityHidden(true)
    }
}

/// Fill behind the primary (Connect Spotify) button: a crayon-coloured blob or a clean capsule.
struct PrimaryButtonBackground: View {
    @Environment(\.theme) private var theme

    var body: some View {
        let shape = WobbleRoundedRect(cornerRadius: theme.buttonCornerRadius, amplitude: theme.wobble * 1.2, seed: 51)
        ZStack {
            shape.fill(theme.primaryFill)
            if theme.isWobbly {
                shape.stroke(theme.background.opacity(0.25), style: StrokeStyle(lineWidth: 1, dash: [1, 3]))
            }
        }
    }
}
