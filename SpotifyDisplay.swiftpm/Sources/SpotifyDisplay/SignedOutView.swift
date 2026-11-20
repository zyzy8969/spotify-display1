import SwiftUI

/// Signed-out screen (Crayon "signed out" artboard; Quiet and Serif reuse it with their tokens).
struct SignedOutScreen: View {
    @ObservedObject var bleManager: BLEManager
    @ObservedObject var spotifyManager: SpotifyManager
    let onOpen: (Panel) -> Void

    @Environment(\.theme) private var theme
    @State private var isSigningIn = false

    var body: some View {
        GeometryReader { geo in
            let bottomPad = ArtMetrics.bottomPadding(safeAreaBottom: geo.safeAreaInsets.bottom)
            let doodleWidth = min(188, geo.size.width * 0.5, geo.size.height * 0.28)
            FitOrScroll {
                VStack(spacing: 0) {
                    StatusHeader(
                        spotifyOn: false,
                        displayOn: bleManager.isConnected,
                        showStatsLink: false,
                        onOpen: onOpen
                    )
                    Spacer(minLength: 16)
                    pitch(doodleWidth: doodleWidth)
                        .padding(.horizontal, 12)
                    Spacer(minLength: 16)
                    Text(theme.id.text(bleManager.isConnected ? .displayReady : .lookingForDisplay))
                        .themeText(.footer)
                        .foregroundStyle(theme.headerLink)
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, theme.margin)
                .padding(.bottom, bottomPad)
                .frame(maxWidth: .infinity)
            }
        }
    }

    private func pitch(doodleWidth: CGFloat) -> some View {
        VStack(spacing: 0) {
            KeychainDoodle()
                .frame(width: doodleWidth, height: doodleWidth * 178 / 188)
            Text(theme.id.text(.idleHeading))
                .themeText(.heading)
                .foregroundStyle(theme.ink)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 28)
                .accessibilityAddTraits(.isHeader)
            Text(theme.id.text(.idleLead))
                .themeText(.lead)
                .foregroundStyle(theme.inkSoft)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 14)
            connectButton
                .padding(.top, 30)
            if let error = spotifyManager.lastError, !error.isEmpty {
                Text(error)
                    .themeText(.footnote)
                    .foregroundStyle(theme.inkSoft)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 14)
            }
        }
    }

    private var connectButton: some View {
        Button {
            isSigningIn = true
            Task {
                await spotifyManager.signInWithSpotify()
                isSigningIn = false
            }
        } label: {
            ZStack {
                Text(theme.id.text(.connectSpotify))
                    .themeText(.button)
                    .foregroundStyle(theme.onPrimary)
                    .opacity(isSigningIn ? 0 : 1)
                if isSigningIn {
                    ProgressView()
                        .tint(theme.onPrimary)
                }
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 12)
            .frame(minHeight: 54)
            .background(PrimaryButtonBackground())
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isSigningIn)
        .accessibilityLabel(theme.id.text(.connectSpotify))
    }
}

/// The keychain drawing from the signed-out artboard, in the theme's hand and palette.
struct KeychainDoodle: View {
    @Environment(\.theme) private var theme

    var body: some View {
        GeometryReader { geo in
            let k = geo.size.width / 188
            let d = theme.doodle
            let w = theme.doodleWidthScale
            ZStack(alignment: .topLeading) {
                line([(94, 16), (95, 11), (100, 8), (107, 9)], width: 7 * w, color: Theme.pick(d, 0), seed: 101, k: k)
                ellipse(cx: 94, cy: 24, r: 9, width: 6 * w, color: Theme.pick(d, 0), seed: 102, k: k)
                ThemedStroke(
                    shape: WobbleRoundedRect(cornerRadius: 14 * k, amplitude: theme.wobble * 1.6, seed: 103),
                    color: Theme.pick(d, 1),
                    lineWidth: max(1, 7 * w * k)
                )
                .frame(width: 120 * k, height: 120 * k)
                .position(x: 94 * k, y: 102 * k)
                ellipse(cx: 76, cy: 84, r: 20, width: 11 * w, color: Theme.pick(d, 2), seed: 104, k: k)
                line([(104, 72), (114, 80), (120, 94), (120, 110)], width: 10 * w, color: Theme.pick(d, 3), seed: 105, k: k)
                line([(54, 132), (80, 122), (108, 124), (134, 136)], width: 10 * w, color: Theme.pick(d, 4), seed: 106, k: k)
                line([(58, 108), (80, 108)], width: 9 * w, color: Theme.pick(d, 5), seed: 107, k: k)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Drawing of the display keychain")
        .accessibilityAddTraits(.isImage)
    }

    private func line(_ points: [(CGFloat, CGFloat)], width: CGFloat, color: Color, seed: UInt64, k: CGFloat) -> some View {
        var unit: [CGPoint] = []
        for point in points {
            unit.append(CGPoint(x: point.0 / 188, y: point.1 / 178))
        }
        return ThemedStroke(
            shape: ScribbleShape(unitPoints: unit, amplitude: theme.wobble * 1.6, seed: seed),
            color: color,
            lineWidth: max(1, width * k)
        )
        .frame(width: 188 * k, height: 178 * k)
    }

    private func ellipse(cx: CGFloat, cy: CGFloat, r: CGFloat, width: CGFloat, color: Color, seed: UInt64, k: CGFloat) -> some View {
        ThemedStroke(
            shape: WobbleEllipse(amplitude: theme.wobble * 1.6, seed: seed),
            color: color,
            lineWidth: max(1, width * k)
        )
        .frame(width: 2 * r * k, height: 2 * r * k)
        .position(x: cx * k, y: cy * k)
    }
}
