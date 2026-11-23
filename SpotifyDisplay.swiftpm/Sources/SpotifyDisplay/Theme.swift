import SwiftUI

// MARK: - Theme identity

/// The three looks from the Design canvas mockup. Persisted by raw value under `storageKey`.
enum ThemeID: String, CaseIterable, Identifiable {
    /// Theme A: white page, hand-drawn crayon marks, Chalkboard SE.
    case crayon
    /// Theme B: near-black, system font, small colour accents.
    case quiet
    /// Theme C: warm paper, the keychain itself drawn around the live cover, tag-style labels,
    /// one signal-orange accent. Replaced the earlier Serif theme.
    case keyring

    static let storageKey = "uiTheme"
    static let fallback: ThemeID = .crayon

    var id: String { rawValue }

    /// Reads the stored raw value, falling back to Crayon for anything unknown. Anyone who had
    /// picked the retired Serif theme lands on Keyring, its replacement.
    static func from(_ raw: String) -> ThemeID {
        if raw == "serif" { return .keyring }
        return ThemeID(rawValue: raw) ?? fallback
    }

    var theme: Theme {
        switch self {
        case .crayon: return .crayon
        case .quiet: return .quiet
        case .keyring: return .keyring
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

/// Colours of the drawn keychain around the cover (Keyring theme).
struct Housing {
    /// The keychain's case.
    var body: Color
    /// Thin edge highlight on the case, so a dark case still reads on any page.
    var edge: Color
    /// The metal key ring and its link.
    var ring: Color
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
    /// Keyring: the cover sits in a drawing of the keychain (body, screen bezel, key ring),
    /// so the screen reads as "this is on your keys right now". nil draws the bare cover.
    var housing: Housing? = nil
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
        t.artFrame = Color(hex: 0xFFD400)
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

    /// Theme C — Keyring. Warm paper, the keychain drawn around the live cover, tag-style mono
    /// labels, one signal orange that means "the keychain" (linked, cached).
    /// Contrast figures are against the #F4F1EA page.
    static let keyring: Theme = {
        var t = Theme(id: .keyring, colorScheme: .light)
        t.background = Color(hex: 0xF4F1EA)
        t.artSurface = Color(hex: 0x2A2925)     // the keychain's screen while it is dark
        t.ink = Color(hex: 0x1C1B19)            // 15.3:1
        t.inkSoft = Color(hex: 0x57554F)        // 6.6:1
        t.inkFaint = Color(hex: 0x67645D)       // 5.2:1
        t.headerLink = Color(hex: 0x1C1B19)
        t.backTint = Color(hex: 0x1C1B19)
        t.control = Color(hex: 0x1C1B19)
        t.controlStrong = Color(hex: 0x1C1B19)
        t.spotify = Color(hex: 0x2E7D32)        // 4.55:1
        t.display = Color(hex: 0xC2410C)        // 4.6:1, the one signal orange
        t.fresh = Color(hex: 0x1C1B19)          // sent fresh: plain ink with a hollow marker
        t.accent = Color(hex: 0xC2410C)
        t.destructive = Color(hex: 0xB3261E)    // 5.8:1
        t.ringOff = Color(hex: 0x7D7A72)        // 3.8:1
        t.toggleOff = Color(hex: 0x7D7A72)
        t.toggleOnFill = Color(hex: 0x1C1B19)
        t.toggleOnKnob = Color(hex: 0xF4F1EA)
        t.sliderTint = Color(hex: 0xC2410C)
        t.primaryFill = Color(hex: 0x1C1B19)
        t.onPrimary = Color(hex: 0xF4F1EA)      // 15.3:1
        t.phaseColors = [Color(hex: 0x1C1B19)]
        t.rule = Color(hex: 0xDDD8CC)
        t.artPalette = [
            Color(hex: 0x3A3833), Color(hex: 0x4E4B45), Color(hex: 0x66625A),
            Color(hex: 0x86827A), Color(hex: 0xC2410C)
        ]
        t.doodle = [
            Color(hex: 0x9A968C), Color(hex: 0x1C1B19), Color(hex: 0x57554F),
            Color(hex: 0xC2410C), Color(hex: 0x9A968C), Color(hex: 0x1C1B19)
        ]
        t.artFrame = nil
        t.housing = Housing(
            body: Color(hex: 0x1C1B19),
            edge: Color(hex: 0x3A3833),
            ring: Color(hex: 0x9A968C)
        )
        t.wobble = 0
        t.iconStroke = 1.6
        t.stripThickness = 3
        t.artCornerRadius = 4
        t.artShadowColor = .clear
        t.artShadowRadius = 0
        t.artShadowY = 0
        t.buttonCornerRadius = 12
        t.doodleWidthScale = 0.6
        t.margin = 22
        t.statsStyle = .thinBars
        t.placeholder = .filledRings
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
