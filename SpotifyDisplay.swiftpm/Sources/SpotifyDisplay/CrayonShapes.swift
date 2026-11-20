import SwiftUI

// The mockup fakes crayon with an SVG feTurbulence displacement filter, which SwiftUI has no
// equivalent for. Instead every mark is a Shape whose outline is nudged sideways by smooth,
// *seeded* noise: the same seed always gives the same wobble, so nothing re-randomises between
// frames and a path is only rebuilt when its size changes. With amplitude 0 the same shapes
// draw crisp geometry, which is how Quiet and Serif reuse them.

// MARK: - Deterministic noise

/// SplitMix64. Tiny, fast and fully deterministic for a given seed.
struct SeededRandom {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed &+ 0x9E37_79B9_7F4A_7C15
    }

    /// Next value in -1...1.
    mutating func next() -> CGFloat {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z = z ^ (z >> 31)
        let unit = Double(z >> 11) / 9_007_199_254_740_992.0 // 2^53
        return CGFloat(unit * 2 - 1)
    }
}

enum Wobble {
    /// A hand-drawn path through `points`. Each segment is split every `step` points and every
    /// sample is pushed along its normal by interpolated noise of size `amplitude`, then the
    /// samples are joined with quadratic curves. `amplitude <= 0` returns straight segments.
    static func path(
        through points: [CGPoint],
        closed: Bool,
        amplitude: CGFloat,
        seed: UInt64,
        step: CGFloat = 4
    ) -> Path {
        var path = Path()
        guard points.count > 1 else { return path }

        guard amplitude > 0 else {
            path.move(to: points[0])
            for point in points.dropFirst() {
                path.addLine(to: point)
            }
            if closed { path.closeSubpath() }
            return path
        }

        // 1. Densify.
        var dense: [CGPoint] = []
        let segmentCount = closed ? points.count : points.count - 1
        for i in 0..<segmentCount {
            let a = points[i]
            let b = points[(i + 1) % points.count]
            let length = hypot(b.x - a.x, b.y - a.y)
            let pieces = max(1, Int((length / max(step, 1)).rounded(.up)))
            for k in 0..<pieces {
                let t = CGFloat(k) / CGFloat(pieces)
                dense.append(CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
            }
        }
        if !closed, let last = points.last {
            dense.append(last)
        }
        guard dense.count > 2 else {
            path.move(to: points[0])
            for point in points.dropFirst() {
                path.addLine(to: point)
            }
            return path
        }

        // 2. Smooth noise: random knots every few samples, linearly interpolated.
        var random = SeededRandom(seed: seed)
        let knotSpacing = 3
        let knotCount = dense.count / knotSpacing + 2
        var knots: [CGFloat] = []
        knots.reserveCapacity(knotCount)
        for _ in 0..<knotCount {
            knots.append(random.next())
        }

        // 3. Offset each sample along its normal.
        var moved: [CGPoint] = []
        moved.reserveCapacity(dense.count)
        let lastIndex = dense.count - 1
        for i in 0...lastIndex {
            let before = dense[max(0, i - 1)]
            let after = dense[min(lastIndex, i + 1)]
            var nx = -(after.y - before.y)
            var ny = after.x - before.x
            let normalLength = max(hypot(nx, ny), 0.0001)
            nx /= normalLength
            ny /= normalLength

            let knotPosition = CGFloat(i) / CGFloat(knotSpacing)
            let k0 = min(Int(knotPosition), knots.count - 1)
            let k1 = min(k0 + 1, knots.count - 1)
            let fraction = knotPosition - CGFloat(k0)
            let noise = knots[k0] * (1 - fraction) + knots[k1] * fraction
            let offset = noise * amplitude
            moved.append(CGPoint(x: dense[i].x + nx * offset, y: dense[i].y + ny * offset))
        }

        // 4. Join through midpoints so the stroke reads as one continuous drag of the crayon.
        path.move(to: moved[0])
        for i in 1..<(moved.count - 1) {
            let mid = CGPoint(x: (moved[i].x + moved[i + 1].x) / 2, y: (moved[i].y + moved[i + 1].y) / 2)
            path.addQuadCurve(to: mid, control: moved[i])
        }
        path.addLine(to: moved[moved.count - 1])
        if closed { path.closeSubpath() }
        return path
    }

    static func ellipsePoints(in rect: CGRect, count: Int = 28) -> [CGPoint] {
        var result: [CGPoint] = []
        result.reserveCapacity(count)
        for i in 0..<count {
            let angle = CGFloat(i) / CGFloat(count) * 2 * .pi - .pi / 2
            result.append(CGPoint(
                x: rect.midX + cos(angle) * rect.width / 2,
                y: rect.midY + sin(angle) * rect.height / 2
            ))
        }
        return result
    }

    static func roundedRectPoints(in rect: CGRect, radius: CGFloat) -> [CGPoint] {
        let r = min(radius, rect.width / 2, rect.height / 2)
        guard r >= 0.5 else {
            return [
                CGPoint(x: rect.minX, y: rect.minY),
                CGPoint(x: rect.maxX, y: rect.minY),
                CGPoint(x: rect.maxX, y: rect.maxY),
                CGPoint(x: rect.minX, y: rect.maxY)
            ]
        }
        let corners: [(CGPoint, CGFloat)] = [
            (CGPoint(x: rect.maxX - r, y: rect.minY + r), -.pi / 2),
            (CGPoint(x: rect.maxX - r, y: rect.maxY - r), 0),
            (CGPoint(x: rect.minX + r, y: rect.maxY - r), .pi / 2),
            (CGPoint(x: rect.minX + r, y: rect.minY + r), .pi)
        ]
        var result: [CGPoint] = []
        for corner in corners {
            for k in 0...5 {
                let angle = corner.1 + CGFloat(k) / 5 * (.pi / 2)
                result.append(CGPoint(x: corner.0.x + cos(angle) * r, y: corner.0.y + sin(angle) * r))
            }
        }
        return result
    }
}

// MARK: - Shapes

/// A horizontal stroke across the middle of its rect. `bow` adds the gentle hand-drawn wave
/// from the mockup's strip; Quiet and Serif pass 0 for a ruler-straight line.
struct WobbleLine: Shape {
    var amplitude: CGFloat = 0
    var bow: CGFloat = 0
    var seed: UInt64 = 1
    var inset: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let x0 = rect.minX + inset
        let x1 = rect.maxX - inset
        let width = x1 - x0
        guard width > 0 else { return Path() }
        let wave: [CGFloat] = [0, -0.5, 0.25, -0.15, 0.35, -0.25, 0]
        var points: [CGPoint] = []
        for i in 0..<wave.count {
            let x = x0 + width * CGFloat(i) / CGFloat(wave.count - 1)
            points.append(CGPoint(x: x, y: rect.midY + wave[i] * bow))
        }
        return Wobble.path(through: points, closed: false, amplitude: amplitude, seed: seed, step: 6)
    }
}

struct WobbleEllipse: Shape {
    var amplitude: CGFloat = 0
    var seed: UInt64 = 2

    func path(in rect: CGRect) -> Path {
        guard amplitude > 0 else { return Path(ellipseIn: rect) }
        let count = max(12, Int(max(rect.width, rect.height) * 0.9))
        return Wobble.path(
            through: Wobble.ellipsePoints(in: rect, count: min(count, 72)),
            closed: true,
            amplitude: amplitude,
            seed: seed,
            step: 3
        )
    }
}

struct WobbleRoundedRect: Shape {
    var cornerRadius: CGFloat
    var amplitude: CGFloat = 0
    var seed: UInt64 = 3

    func path(in rect: CGRect) -> Path {
        guard amplitude > 0 else {
            return Path(roundedRect: rect, cornerRadius: min(cornerRadius, rect.width / 2, rect.height / 2))
        }
        return Wobble.path(
            through: Wobble.roundedRectPoints(in: rect, radius: cornerRadius),
            closed: true,
            amplitude: amplitude,
            seed: seed,
            step: 5
        )
    }
}

/// A free polyline given in unit coordinates (0...1 of the rect), for doodles.
struct ScribbleShape: Shape {
    var unitPoints: [CGPoint]
    var closed: Bool = false
    var amplitude: CGFloat = 0
    var seed: UInt64 = 4

    func path(in rect: CGRect) -> Path {
        var points: [CGPoint] = []
        points.reserveCapacity(unitPoints.count)
        for p in unitPoints {
            points.append(CGPoint(x: rect.minX + p.x * rect.width, y: rect.minY + p.y * rect.height))
        }
        return Wobble.path(through: points, closed: closed, amplitude: amplitude, seed: seed, step: 5)
    }
}

// MARK: - Icon glyphs

/// The app's small icon set, drawn on a 20x20 grid so one definition serves all three themes.
enum Glyph: UInt64 {
    case gear = 11
    case chevronLeft = 12
    case chevronDown = 13
    case previous = 14
    case next = 15
    case play = 16
    case pause = 17

    var isFilled: Bool {
        switch self {
        case .previous, .next, .play, .pause: return true
        case .gear, .chevronLeft, .chevronDown: return false
        }
    }
}

struct GlyphShape: Shape {
    var glyph: Glyph
    var amplitude: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let side = min(rect.width, rect.height)
        let scale = side / 20
        let originX = rect.midX - side / 2
        let originY = rect.midY - side / 2
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: originX + x * scale, y: originY + y * scale)
        }
        let seed = glyph.rawValue
        var path = Path()

        func add(_ points: [CGPoint], closed: Bool, salt: UInt64) {
            path.addPath(Wobble.path(through: points, closed: closed, amplitude: amplitude, seed: seed &* 31 &+ salt, step: 2.5))
        }
        func addBox(_ x0: CGFloat, _ y0: CGFloat, _ x1: CGFloat, _ y1: CGFloat, salt: UInt64) {
            add([pt(x0, y0), pt(x1, y0), pt(x1, y1), pt(x0, y1)], closed: true, salt: salt)
        }

        switch glyph {
        case .gear:
            let hub = CGRect(x: originX + 7 * scale, y: originY + 7 * scale, width: 6 * scale, height: 6 * scale)
            if amplitude > 0 {
                add(Wobble.ellipsePoints(in: hub, count: 16), closed: true, salt: 1)
            } else {
                path.addEllipse(in: hub)
            }
            let spokes: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [
                (10, 1.6, 10, 4.0), (10, 16.0, 10, 18.4),
                (16.9, 6.0, 15.2, 7.0), (4.8, 13.0, 3.1, 14.0),
                (16.9, 14.0, 15.2, 13.0), (4.8, 7.0, 3.1, 6.0)
            ]
            for (index, s) in spokes.enumerated() {
                add([pt(s.0, s.1), pt(s.2, s.3)], closed: false, salt: UInt64(index) + 2)
            }
        case .chevronLeft:
            add([pt(12.4, 3.6), pt(5.6, 10), pt(12.4, 16.4)], closed: false, salt: 1)
        case .chevronDown:
            add([pt(3.6, 7.0), pt(10, 13.6), pt(16.4, 7.0)], closed: false, salt: 1)
        case .previous:
            add([pt(16.6, 3.6), pt(16.6, 16.4), pt(7.4, 10)], closed: true, salt: 1)
            addBox(5.0, 3.6, 7.2, 16.4, salt: 2)
        case .next:
            add([pt(3.4, 3.6), pt(3.4, 16.4), pt(12.6, 10)], closed: true, salt: 1)
            addBox(12.8, 3.6, 15.0, 16.4, salt: 2)
        case .play:
            add([pt(5.5, 3.0), pt(5.5, 17.0), pt(17.0, 10.0)], closed: true, salt: 1)
        case .pause:
            addBox(4.4, 3.0, 8.4, 17.0, salt: 1)
            addBox(11.6, 3.0, 15.6, 17.0, salt: 2)
        }
        return path
    }
}

// MARK: - Themed mark views

/// Strokes `shape` in the theme's hand: a waxy crayon line (with paper showing through)
/// when the theme wobbles, a clean stroke otherwise.
struct ThemedStroke<S: Shape>: View {
    let shape: S
    let color: Color
    let lineWidth: CGFloat
    var dash: [CGFloat] = []
    @Environment(\.theme) private var theme

    var body: some View {
        ZStack {
            shape.stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round, dash: dash))
            if theme.isWobbly && dash.isEmpty && lineWidth >= 2 {
                shape.stroke(
                    theme.background.opacity(0.4),
                    style: StrokeStyle(lineWidth: max(0.6, lineWidth * 0.28), lineCap: .round, dash: [0.8, 2.6])
                )
            }
        }
    }
}

/// One of the app's icons at `size` points, in the theme's hand.
struct GlyphIcon: View {
    let glyph: Glyph
    let color: Color
    let size: CGFloat
    @Environment(\.theme) private var theme

    var body: some View {
        let shape = GlyphShape(glyph: glyph, amplitude: theme.wobble * 0.5)
        ZStack {
            if glyph.isFilled {
                shape.fill(color)
                if theme.isWobbly {
                    shape.stroke(theme.background.opacity(0.3), style: StrokeStyle(lineWidth: 0.7, dash: [0.7, 2.2]))
                }
            } else {
                ThemedStroke(shape: shape, color: color, lineWidth: theme.iconStroke * size / 22)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// The app's one non-colour state cue: a filled dot means "yes" (connected, cached),
/// a hollow ring means "no" / "the other kind" (not connected, sent fresh).
struct StateMarker: View {
    let filled: Bool
    let fillColor: Color
    let ringColor: Color
    let size: CGFloat
    @Environment(\.theme) private var theme

    var body: some View {
        let shape = WobbleEllipse(amplitude: theme.wobble * size * 0.05, seed: filled ? 7 : 8)
        let ringWidth = max(1.5, size * 0.17)
        ZStack {
            if filled {
                shape.fill(fillColor)
            } else {
                shape.stroke(ringColor, lineWidth: ringWidth)
                    .padding(ringWidth / 2)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// A divider: a faint crayon line, or a 1pt hairline.
struct ThemedDivider: View {
    @Environment(\.theme) private var theme

    var body: some View {
        Group {
            if theme.isWobbly {
                ThemedStroke(
                    shape: WobbleLine(amplitude: theme.wobble * 0.8, bow: 1.5, seed: 41, inset: 2),
                    color: theme.rule,
                    lineWidth: 3
                )
                .frame(height: 8)
            } else {
                Rectangle()
                    .fill(theme.rule)
                    .frame(height: 1)
            }
        }
        .accessibilityHidden(true)
    }
}
