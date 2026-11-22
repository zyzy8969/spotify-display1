import SwiftUI

// MARK: - Theme identity

/// The looks from the Design canvas mockup, each with a day and a night version. Persisted by raw
/// value under `storageKey`. (Serif was removed 2026-11-22; a stored "serif" falls back to Crayon.)
enum ThemeID: String, CaseIterable, Identifiable {
    /// Theme A: hand-drawn crayon marks, Chalkboard SE. Day: white page; night: chalkboard.
    case crayon
    /// Theme B: system font, small colour accents. Night (its original): near-black; day: light grey.
    case quiet

    static let storageKey = "uiTheme"
    static let fallback: ThemeID = .crayon

    var id: String { rawValue }

    /// Reads the stored raw value, falling back to Crayon for anything unknown.
    static func from(_ raw: String) -> ThemeID {
        ThemeID(rawValue: raw) ?? fallback
    }

    /// Where this theme's night switch is stored (one per theme, so each keeps its own choice).
    var darkKey: String { "uiDark.\(rawValue)" }
    /// Crayon starts in day mode, Quiet in night mode, as designed.
    var defaultDark: Bool { self == .quiet }

    /// The theme in its default mode.
    var theme: Theme { theme(dark: defaultDark) }

    func theme(dark: Bool) -> Theme {
        switch self {
        case .crayon: return dark ? .crayonNight : .crayon
        case .quiet: return dark ? .quiet : .quietDay
        }
    }

    /// A few of the theme's own colours, for its swatch in Settings.
    func swatch(dark: Bool) -> [Color] {
        let t = theme(dark: dark)
        switch self {
        case .crayon: return Array(t.artPalette.prefix(5))
        case .quiet: return [t.ink, t.spotify, t.display, t.inkSoft]
        }
    }
}

/// How the Stats screen draws the per-phase timing breakdown.
enum StatsStyle {
    /// Thick hand-drawn bars, one colour per phase (Crayon).
    case crayonBars
    /// Thin flat bars on a dim track (Quiet).
    case thinBars
    /// No bars: dotted leaders between name and value, slowest step in the accent (Serif).
    case dotLeaders
}

/// What the album-art slot shows before any cover has arrived.
enum PlaceholderStyle {
    case scribbles
    case filledRings
    case hairlineRings
}

// MARK: - Tokens

/// Every colour, metric and style switch a screen needs. Screens read this from the
/// environment (`@Environment(\.theme)`) and never branch on the theme name for colour.
///
/// Contrast (WCAG 2.x, against `background`): every *text* token is at least 4.5:1, every
/// state-carrying *mark* token (`ringOff`, `toggleOff`, `fresh`, `display`, `spotify`) at
/// least 3:1. Tokens documented as decorative (`rule`, `artPalette`, `doodle`) carry no meaning.
struct Theme {
    var id: ThemeID
    var colorScheme: ColorScheme

    // Surfaces
    var background: Color = .white
    var artSurface: Color = .white

    // Text
    var ink: Color = .black
    var inkSoft: Color = .gray
    var inkFaint: Color = .gray
    var headerLink: Color = .black
    var backTint: Color = .black

    // Marks with meaning
    var control: Color = .black
    var controlStrong: Color = .black
    var spotify: Color = .green
    var display: Color = .blue
    var fresh: Color = .orange
    var accent: Color = .red
    var destructive: Color = .red
    var ringOff: Color = .gray
    var toggleOff: Color = .gray
    var toggleOnFill: Color = .black
    var toggleOnKnob: Color = .white
    var sliderTint: Color = .black
    var primaryFill: Color = .black
    var onPrimary: Color = .white

    /// Per-phase colours for `.crayonBars` / `.thinBars`: lookup, download, convert, send, other.
    var phaseColors: [Color] = [.black]

    // Decorative only
    var rule: Color = .gray
    var artPalette: [Color] = [.gray]
    var doodle: [Color] = [.gray]
    var artFrame: Color? = nil

    // Shape and metrics
    /// Crayon wobble strength. 0 draws crisp geometry; 1 is the Crayon look.
    var wobble: CGFloat = 0
    var iconStroke: CGFloat = 1.4
    var stripThickness: CGFloat = 2
    var artCornerRadius: CGFloat = 6
    var artShadowColor: Color = .clear
    var artShadowRadius: CGFloat = 0
    var artShadowY: CGFloat = 0
    var artBorder: Color? = nil
    var buttonCornerRadius: CGFloat = 27
    var doodleWidthScale: CGFloat = 1
    var margin: CGFloat = 22

    var statsStyle: StatsStyle = .thinBars
    var placeholder: PlaceholderStyle = .filledRings
    /// Stats hero: Serif puts its small-caps "Last transfer" label above the big number.
    var heroLabelAbove: Bool = false

    var isWobbly: Bool { wobble > 0 }

    /// Safe palette lookup for decorative colour lists.
    static func pick(_ palette: [Color], _ index: Int) -> Color {
        guard !palette.isEmpty else { return .gray }
        return palette[index % palette.count]
    }
}

// MARK: - The three themes

extension Theme {
    /// Theme A — Crayon. Words near-black, colour lives only in the drawn marks.
    static let crayon: Theme = {
        var t = Theme(id: .crayon, colorScheme: .light)
        t.background = Color(hex: 0xFFFFFF)
        t.artSurface = Color(hex: 0xFBFBF9)
        t.ink = Color(hex: 0x1A1A1A)            // 17.4:1
        t.inkSoft = Color(hex: 0x5A5A5A)        // 6.9:1
        t.inkFaint = Color(hex: 0x6B6B6B)       // 5.3:1
        t.headerLink = Color(hex: 0x1A1A1A)
        t.backTint = Color(hex: 0x1565C0)       // 5.75:1
        t.control = Color(hex: 0x1A1A1A)
        t.controlStrong = Color(hex: 0x1A1A1A)
        t.spotify = Color(hex: 0x2E7D32)        // 5.1:1 (mockup #2BB24C is 2.8:1)
        t.display = Color(hex: 0x1565C0)        // 5.75:1
        t.fresh = Color(hex: 0xE65100)          // 3.8:1, marks only
        t.accent = Color(hex: 0x6A1B9A)
        t.destructive = Color(hex: 0xC62828)    // 5.6:1
        t.ringOff = Color(hex: 0x767676)        // 4.5:1
        t.toggleOff = Color(hex: 0x767676)      // mockup #C4C4C0 fails 3:1
        t.toggleOnFill = Color(hex: 0x2E7D32)
        t.toggleOnKnob = Color(hex: 0xFFFFFF)
        t.sliderTint = Color(hex: 0x1565C0)
        t.primaryFill = Color(hex: 0x2E7D32)    // white on it: 5.1:1
        t.onPrimary = Color(hex: 0xFFFFFF)
        t.phaseColors = [
            Color(hex: 0x1565C0), // lookup: the display's cache
            Color(hex: 0x2E7D32), // download: from Spotify
            Color(hex: 0x6A1B9A), // convert: colours
            Color(hex: 0xE65100), // send: fresh transfer
            Color(hex: 0x767676)  // other
        ]
        t.rule = Color(hex: 0xE4E4E0)
        t.artPalette = [
            Color(hex: 0xFF8A00), Color(hex: 0x1E7FFF), Color(hex: 0xFF2D20),
            Color(hex: 0xFFD400), Color(hex: 0x9B2FD6), Color(hex: 0x00B38A)
        ]
        t.doodle = [
            Color(hex: 0xA8A8A8), Color(hex: 0x1A1A1A), Color(hex: 0xF2742C),
            Color(hex: 0x3B7DD8), Color(hex: 0xE8453C), Color(hex: 0xF5B924)
        ]
        // The yellow hand-drawn outline behind the cover was removed by request (2026-11-22).
        t.artFrame = nil
        t.wobble = 1
        t.iconStroke = 2.4
        t.stripThickness = 6
        t.artCornerRadius = 6
        t.artShadowColor = Color(hex: 0x1A1A1A, opacity: 0.14)
        t.artShadowRadius = 13
        t.artShadowY = 10
        t.buttonCornerRadius = 27
        t.doodleWidthScale = 1
        t.margin = 22
        t.statsStyle = .crayonBars
        t.placeholder = .scribbles
        return t
    }()

    /// Theme B — Quiet. Dark, system type, colour only in the two status dots and the cached strip.
    static let quiet: Theme = {
        var t = Theme(id: .quiet, colorScheme: .dark)
        t.background = Color(hex: 0x0C0C0C)
        t.artSurface = Color(hex: 0x141414)
        t.ink = Color(hex: 0xFFFFFF)            // 19.6:1
        t.inkSoft = Color(hex: 0x9B9B9B)        // 7.0:1
        t.inkFaint = Color(hex: 0x8A8A8A)       // 5.7:1
        t.headerLink = Color(hex: 0x9B9B9B)
        t.backTint = Color(hex: 0x9B9B9B)
        t.control = Color(hex: 0x9B9B9B)
        t.controlStrong = Color(hex: 0xFFFFFF)
        t.spotify = Color(hex: 0x34C759)        // 8.8:1
        t.display = Color(hex: 0x4FC3F7)        // 9.8:1
        t.fresh = Color(hex: 0xFFFFFF)
        t.accent = Color(hex: 0x4FC3F7)
        t.destructive = Color(hex: 0xFFFFFF)    // mockup: plain white, guarded by an alert
        t.ringOff = Color(hex: 0x8A8A8A)        // 5.7:1
        t.toggleOff = Color(hex: 0x6E6E6E)      // 3.8:1 (mockup #4A4A4A is 2.2:1)
        t.toggleOnFill = Color(hex: 0xFFFFFF)
        t.toggleOnKnob = Color(hex: 0x0C0C0C)
        t.sliderTint = Color(hex: 0xFFFFFF)
        t.primaryFill = Color(hex: 0xFFFFFF)
        t.onPrimary = Color(hex: 0x0C0C0C)
        t.phaseColors = [Color(hex: 0xFFFFFF)]
        t.rule = Color(hex: 0x1E1E1E)
        t.artPalette = [
            Color(hex: 0x1F1F1F), Color(hex: 0x3A3A3A), Color(hex: 0x6E6E6E),
            Color(hex: 0x9B9B9B), Color(hex: 0xE8E8E8)
        ]
        t.doodle = [
            Color(hex: 0x6E6E6E), Color(hex: 0xE8E8E8), Color(hex: 0x9B9B9B),
            Color(hex: 0x4FC3F7), Color(hex: 0x6E6E6E), Color(hex: 0x34C759)
        ]
        t.artFrame = nil
        t.wobble = 0
        t.iconStroke = 1.4
        t.stripThickness = 2
        t.artCornerRadius = 6
        t.artShadowColor = Color(hex: 0x000000, opacity: 0.8)
        t.artShadowRadius = 22
        t.artShadowY = 18
        t.buttonCornerRadius = 27
        t.doodleWidthScale = 0.7
        t.margin = 22
        t.statsStyle = .thinBars
        t.placeholder = .filledRings
        return t
    }()

    /// Crayon at night: chalk on a chalkboard. Same marks and wobble as Crayon, light ink on a dark
    /// slate; the colours are lifted so they keep their contrast against the dark page.
    static let crayonNight: Theme = {
        var t = Theme.crayon
        t.colorScheme = .dark
        t.background = Color(hex: 0x16191D)
        t.artSurface = Color(hex: 0x1F2328)
        t.ink = Color(hex: 0xF2F1EC)            // 16.0:1
        t.inkSoft = Color(hex: 0xB9B8B1)        // 9.0:1
        t.inkFaint = Color(hex: 0x9E9D97)       // 6.6:1
        t.headerLink = Color(hex: 0xF2F1EC)
        t.backTint = Color(hex: 0x64B5F6)
        t.control = Color(hex: 0xF2F1EC)
        t.controlStrong = Color(hex: 0xF2F1EC)
        t.spotify = Color(hex: 0x66BB6A)        // 7.4:1
        t.display = Color(hex: 0x64B5F6)        // 7.6:1
        t.fresh = Color(hex: 0xFFA040)          // 8.5:1
        t.accent = Color(hex: 0xCE93D8)
        t.destructive = Color(hex: 0xFF7A70)    // 6.6:1
        t.ringOff = Color(hex: 0x8C8B85)        // 5.1:1
        t.toggleOff = Color(hex: 0x8C8B85)
        t.toggleOnFill = Color(hex: 0x66BB6A)
        t.toggleOnKnob = Color(hex: 0x16191D)
        t.sliderTint = Color(hex: 0x64B5F6)
        t.primaryFill = Color(hex: 0x66BB6A)
        t.onPrimary = Color(hex: 0x10130F)      // 8.0:1 on the green
        t.phaseColors = [
            Color(hex: 0x64B5F6), Color(hex: 0x66BB6A), Color(hex: 0xCE93D8),
            Color(hex: 0xFFA040), Color(hex: 0x8C8B85)
        ]
        t.rule = Color(hex: 0x2C3137)
        t.doodle = [
            Color(hex: 0x6C7076), Color(hex: 0xF2F1EC), Color(hex: 0xF2742C),
            Color(hex: 0x5C9CEB), Color(hex: 0xE8453C), Color(hex: 0xF5B924)
        ]
        t.artShadowColor = Color(hex: 0x000000, opacity: 0.5)
        return t
    }()

    /// Quiet by day: the same restraint on a soft light-grey page; colour still only in the dots.
    static let quietDay: Theme = {
        var t = Theme.quiet
        t.colorScheme = .light
        t.background = Color(hex: 0xF4F4F2)
        t.artSurface = Color(hex: 0xE9E9E6)
        t.ink = Color(hex: 0x0C0C0C)            // 18.1:1
        t.inkSoft = Color(hex: 0x5A5A5A)        // 6.3:1
        t.inkFaint = Color(hex: 0x666666)       // 5.2:1
        t.headerLink = Color(hex: 0x5A5A5A)
        t.backTint = Color(hex: 0x5A5A5A)
        t.control = Color(hex: 0x5A5A5A)
        t.controlStrong = Color(hex: 0x0C0C0C)
        t.spotify = Color(hex: 0x1E8E3E)        // 3.9:1, marks only
        t.display = Color(hex: 0x0277BD)        // 4.6:1
        t.fresh = Color(hex: 0x0C0C0C)
        t.accent = Color(hex: 0x0277BD)
        t.destructive = Color(hex: 0x0C0C0C)
        t.ringOff = Color(hex: 0x767676)        // 4.1:1
        t.toggleOff = Color(hex: 0x8A8A8A)      // 3.2:1
        t.toggleOnFill = Color(hex: 0x0C0C0C)
        t.toggleOnKnob = Color(hex: 0xF4F4F2)
        t.sliderTint = Color(hex: 0x0C0C0C)
        t.primaryFill = Color(hex: 0x0C0C0C)
        t.onPrimary = Color(hex: 0xFFFFFF)
        t.phaseColors = [Color(hex: 0x0C0C0C)]
        t.rule = Color(hex: 0xDEDEDB)
        t.artPalette = [
            Color(hex: 0xE0E0DD), Color(hex: 0xC4C4C0), Color(hex: 0x9B9B9B),
            Color(hex: 0x6E6E6E), Color(hex: 0x2A2A2A)
        ]
        t.doodle = [
            Color(hex: 0x9B9B9B), Color(hex: 0x2A2A2A), Color(hex: 0x6E6E6E),
            Color(hex: 0x0277BD), Color(hex: 0x9B9B9B), Color(hex: 0x1E8E3E)
        ]
        t.artShadowColor = Color(hex: 0x000000, opacity: 0.14)
        t.artShadowRadius = 18
        t.artShadowY = 12
        return t
    }()
}

// MARK: - Environment

private struct ThemeEnvironmentKey: EnvironmentKey {
    static let defaultValue: Theme = .crayon
}

extension EnvironmentValues {
    var theme: Theme {
        get { self[ThemeEnvironmentKey.self] }
        set { self[ThemeEnvironmentKey.self] = newValue }
    }
}

// MARK: - Helpers

extension Color {
    /// `0xRRGGBB` in sRGB.
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }
}
