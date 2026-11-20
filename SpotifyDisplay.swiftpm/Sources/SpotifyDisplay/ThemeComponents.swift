import SwiftUI

/// Which sheet is open over the main screen.
enum Panel: String, Identifiable {
    case settings
    case stats

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
            .buttonStyle(.plain)
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

extension View {
    /// Disables the rubber-band bounce when a scroll view's content already fits (iOS 16.4+).
    @ViewBuilder
    func bounceOnlyWhenScrollable() -> some View {
        if #available(iOS 16.4, *) {
            self.scrollBounceBehavior(.basedOnSize)
        } else {
            self
        }
    }
}
