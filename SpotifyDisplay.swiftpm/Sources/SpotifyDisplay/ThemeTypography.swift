import SwiftUI
import UIKit

/// What a piece of text *is*. Each theme maps a role to its own face, size and case.
enum TextRole {
    case trackTitle
    case trackArtist
    case statusLabel
    case headerLink
    case footer
    case footnote
    case row
    case rowValue
    case button
    case heading
    case lead
    case sheetTitle
    case statBig
    case statUnit
    case eyebrow
    case phaseName
    case phaseValue
    case statNumber
    case statCaption
    /// Debug/live detail. Always system monospaced, scaled from `.caption2`.
    case mono
}

enum FontFace {
    case light, regular, semibold, bold, italic
}

enum FontFamily {
    case chalkboard, system, times
}

struct TextSpec {
    var size: CGFloat
    /// Dynamic Type anchor: the text scales with this style.
    var style: Font.TextStyle
    var face: FontFace = .regular
    var tracking: CGFloat = 0
    var uppercase: Bool = false
}

extension ThemeID {
    var fontFamily: FontFamily {
        switch self {
        case .crayon: return .chalkboard
        case .quiet: return .system
        case .serif: return .times
        }
    }

    func textSpec(_ role: TextRole) -> TextSpec {
        switch self {
        case .crayon: return Self.crayonSpec(role)
        case .quiet: return Self.quietSpec(role)
        case .serif: return Self.serifSpec(role)
        }
    }

    // Sizes come from the 390x844 artboards; minimum on-screen size is 11pt.
    private static func crayonSpec(_ role: TextRole) -> TextSpec {
        switch role {
        case .trackTitle: return TextSpec(size: 28, style: .title, face: .bold)
        case .trackArtist: return TextSpec(size: 19, style: .title3, face: .bold)
        case .statusLabel: return TextSpec(size: 13, style: .footnote)
        case .headerLink: return TextSpec(size: 17, style: .body, face: .bold)
        case .footer: return TextSpec(size: 17, style: .body, face: .bold)
        case .footnote: return TextSpec(size: 14, style: .footnote)
        case .row: return TextSpec(size: 20, style: .title3, face: .bold)
        case .rowValue: return TextSpec(size: 18, style: .body, face: .bold)
        case .button: return TextSpec(size: 19, style: .headline, face: .bold)
        case .heading: return TextSpec(size: 34, style: .largeTitle, face: .bold)
        case .lead: return TextSpec(size: 16, style: .callout)
        case .sheetTitle: return TextSpec(size: 26, style: .title2, face: .bold)
        case .statBig: return TextSpec(size: 72, style: .largeTitle, face: .bold)
        case .statUnit: return TextSpec(size: 22, style: .title2, face: .bold)
        case .eyebrow: return TextSpec(size: 15, style: .subheadline)
        case .phaseName: return TextSpec(size: 15, style: .subheadline)
        case .phaseValue: return TextSpec(size: 15, style: .subheadline, face: .bold)
        case .statNumber: return TextSpec(size: 32, style: .title, face: .bold)
        case .statCaption: return TextSpec(size: 14, style: .footnote)
        case .mono: return TextSpec(size: 11, style: .caption2)
        }
    }

    private static func quietSpec(_ role: TextRole) -> TextSpec {
        switch role {
        case .trackTitle: return TextSpec(size: 22, style: .title2, face: .semibold)
        case .trackArtist: return TextSpec(size: 15, style: .subheadline)
        case .statusLabel: return TextSpec(size: 12, style: .caption)
        case .headerLink: return TextSpec(size: 13, style: .footnote)
        case .footer: return TextSpec(size: 12, style: .caption)
        case .footnote: return TextSpec(size: 13, style: .footnote)
        case .row: return TextSpec(size: 15, style: .subheadline)
        case .rowValue: return TextSpec(size: 13, style: .footnote)
        case .button: return TextSpec(size: 17, style: .headline, face: .semibold)
        case .heading: return TextSpec(size: 28, style: .title, face: .semibold)
        case .lead: return TextSpec(size: 15, style: .subheadline)
        case .sheetTitle: return TextSpec(size: 20, style: .title3, face: .semibold)
        case .statBig: return TextSpec(size: 64, style: .largeTitle, face: .light)
        case .statUnit: return TextSpec(size: 13, style: .footnote, tracking: 1, uppercase: true)
        case .eyebrow: return TextSpec(size: 13, style: .footnote)
        case .phaseName: return TextSpec(size: 13, style: .footnote)
        case .phaseValue: return TextSpec(size: 13, style: .footnote)
        case .statNumber: return TextSpec(size: 28, style: .title, face: .light)
        case .statCaption: return TextSpec(size: 12, style: .caption)
        case .mono: return TextSpec(size: 11, style: .caption2)
        }
    }

    private static func serifSpec(_ role: TextRole) -> TextSpec {
        switch role {
        case .trackTitle: return TextSpec(size: 27, style: .title)
        case .trackArtist: return TextSpec(size: 17, style: .body, face: .italic)
        case .statusLabel: return TextSpec(size: 12, style: .caption, tracking: 1.7, uppercase: true)
        case .headerLink: return TextSpec(size: 12, style: .caption, tracking: 1.7, uppercase: true)
        case .footer: return TextSpec(size: 12, style: .caption, tracking: 1.7, uppercase: true)
        case .footnote: return TextSpec(size: 15, style: .subheadline)
        case .row: return TextSpec(size: 17, style: .body)
        case .rowValue: return TextSpec(size: 17, style: .body, face: .italic)
        case .button: return TextSpec(size: 18, style: .headline)
        case .heading: return TextSpec(size: 32, style: .largeTitle)
        case .lead: return TextSpec(size: 17, style: .body, face: .italic)
        case .sheetTitle: return TextSpec(size: 24, style: .title2)
        case .statBig: return TextSpec(size: 68, style: .largeTitle)
        case .statUnit: return TextSpec(size: 22, style: .title2, face: .italic)
        case .eyebrow: return TextSpec(size: 12, style: .caption, tracking: 1.7, uppercase: true)
        case .phaseName: return TextSpec(size: 16, style: .callout)
        case .phaseValue: return TextSpec(size: 16, style: .callout)
        case .statNumber: return TextSpec(size: 30, style: .title)
        case .statCaption: return TextSpec(size: 11, style: .caption2, tracking: 1.3, uppercase: true)
        case .mono: return TextSpec(size: 11, style: .caption2)
        }
    }
}

// MARK: - Font construction

enum ThemeFonts {
    static func font(
        for spec: TextSpec,
        family: FontFamily,
        boldText: Bool,
        dynamicTypeSize: DynamicTypeSize
    ) -> Font {
        switch family {
        case .chalkboard:
            // Chalkboard SE ships with iOS in Light, Regular and Bold (no italic).
            let name: String
            switch spec.face {
            case .bold, .semibold:
                name = "ChalkboardSE-Bold"
            case .light:
                name = boldText ? "ChalkboardSE-Regular" : "ChalkboardSE-Light"
            case .regular, .italic:
                name = boldText ? "ChalkboardSE-Bold" : "ChalkboardSE-Regular"
            }
            return .custom(name, size: spec.size, relativeTo: spec.style)

        case .times:
            let name: String
            switch spec.face {
            case .italic:
                name = boldText ? "TimesNewRomanPS-BoldItalicMT" : "TimesNewRomanPS-ItalicMT"
            case .bold, .semibold:
                name = "TimesNewRomanPS-BoldMT"
            case .light, .regular:
                name = boldText ? "TimesNewRomanPS-BoldMT" : "TimesNewRomanPSMT"
            }
            return .custom(name, size: spec.size, relativeTo: spec.style)

        case .system:
            // `Font.system(size:)` does not scale on its own, so scale the artboard size
            // through UIFontMetrics for the current Dynamic Type setting.
            let size = scaledSize(spec.size, style: spec.style, dynamicTypeSize: dynamicTypeSize)
            let weight: Font.Weight
            switch spec.face {
            case .light: weight = boldText ? .regular : .light
            case .regular, .italic: weight = boldText ? .semibold : .regular
            case .semibold: weight = boldText ? .bold : .semibold
            case .bold: weight = boldText ? .heavy : .bold
            }
            let base = Font.system(size: size, weight: weight)
            return spec.face == .italic ? base.italic() : base
        }
    }

    static func scaledSize(_ size: CGFloat, style: Font.TextStyle, dynamicTypeSize: DynamicTypeSize) -> CGFloat {
        let traits = UITraitCollection(preferredContentSizeCategory: contentSizeCategory(for: dynamicTypeSize))
        return UIFontMetrics(forTextStyle: uiTextStyle(for: style)).scaledValue(for: size, compatibleWith: traits)
    }

    private static func uiTextStyle(for style: Font.TextStyle) -> UIFont.TextStyle {
        switch style {
        case .largeTitle: return .largeTitle
        case .title: return .title1
        case .title2: return .title2
        case .title3: return .title3
        case .headline: return .headline
        case .subheadline: return .subheadline
        case .body: return .body
        case .callout: return .callout
        case .footnote: return .footnote
        case .caption: return .caption1
        case .caption2: return .caption2
        @unknown default: return .body
        }
    }

    private static func contentSizeCategory(for size: DynamicTypeSize) -> UIContentSizeCategory {
        switch size {
        case .xSmall: return .extraSmall
        case .small: return .small
        case .medium: return .medium
        case .large: return .large
        case .xLarge: return .extraLarge
        case .xxLarge: return .extraExtraLarge
        case .xxxLarge: return .extraExtraExtraLarge
        case .accessibility1: return .accessibilityMedium
        case .accessibility2: return .accessibilityLarge
        case .accessibility3: return .accessibilityExtraLarge
        case .accessibility4: return .accessibilityExtraExtraLarge
        case .accessibility5: return .accessibilityExtraExtraExtraLarge
        @unknown default: return .large
        }
    }
}

// MARK: - Modifier

/// Applies the current theme's face, size, tracking and case for `role`.
/// Honours Dynamic Type (via `relativeTo:` / UIFontMetrics) and the Bold Text setting.
struct ThemeTextModifier: ViewModifier {
    let role: TextRole
    @Environment(\.theme) private var theme
    @Environment(\.legibilityWeight) private var legibilityWeight
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    func body(content: Content) -> some View {
        let spec = theme.id.textSpec(role)
        let font: Font = role == .mono
            ? .system(.caption2, design: .monospaced)
            : ThemeFonts.font(
                for: spec,
                family: theme.id.fontFamily,
                boldText: legibilityWeight == .bold,
                dynamicTypeSize: dynamicTypeSize
            )
        return content
            .font(font)
            .tracking(spec.tracking)
            .textCase(spec.uppercase ? .uppercase : nil)
    }
}

extension View {
    func themeText(_ role: TextRole) -> some View {
        modifier(ThemeTextModifier(role: role))
    }
}
