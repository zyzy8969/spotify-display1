import SwiftUI

// MARK: - Catalog

/// One transition the board can draw. `id` is the BLE header index (docs/BLE_PROTOCOL.md) and `name`
/// is exactly the string the firmware announces in `TRANSITION:<name>` (`getTransitionName`).
struct TransitionInfo: Identifiable, Hashable {
    let id: Int
    let name: String
    /// In the firmware's QUICK_TRANSITIONS list: the set used for new songs when nothing is switched off.
    let quick: Bool
    let blurb: String

    /// Rough on-screen length of the in-app preview. The board's real draw time varies per effect.
    var duration: Double { quick ? 0.7 : 1.1 }
}

enum TransitionCatalog {
    /// Every live transition (retired indices 5, 10 and 16 are not listed), in header-index order.
    static let all: [TransitionInfo] = [
        .init(id: 0, name: "Wipe Up", quick: true, blurb: "Reveals from the bottom edge upward"),
        .init(id: 1, name: "Wipe Right", quick: false, blurb: "Reveals from left to right"),
        .init(id: 2, name: "Wipe Left", quick: false, blurb: "Reveals from right to left"),
        .init(id: 3, name: "Circular", quick: false, blurb: "A circle grows from the centre"),
        .init(id: 4, name: "Checkerboard", quick: true, blurb: "Alternate squares dissolve in"),
        .init(id: 6, name: "Diagonal", quick: false, blurb: "Wipes from top-left to bottom-right"),
        .init(id: 7, name: "Diagonal Inverse", quick: false, blurb: "Wipes from bottom-right to top-left"),
        .init(id: 8, name: "Venetian V", quick: true, blurb: "Vertical blinds open"),
        .init(id: 9, name: "Four Corner", quick: false, blurb: "Wipes in from all four corners"),
        .init(id: 11, name: "Zoom Blocks", quick: true, blurb: "A square grows from the centre"),
        .init(id: 12, name: "Horizontal Split", quick: false, blurb: "Opens from a line across the middle"),
        .init(id: 13, name: "Vertical Split", quick: true, blurb: "Opens from a line down the middle"),
        .init(id: 14, name: "Barn Doors", quick: false, blurb: "Doors swing open from the centre"),
        .init(id: 15, name: "Random Blocks", quick: true, blurb: "Blocks pop in at random"),
        .init(id: 17, name: "Checker Cascade", quick: false, blurb: "Checkerboard rippling diagonally"),
        .init(id: 18, name: "Card Stack", quick: false, blurb: "New cover slides over the old one"),
        .init(id: 19, name: "Static Dissolve", quick: false, blurb: "Fine random-pixel dissolve"),
        .init(id: 20, name: "Dither Fade", quick: false, blurb: "Ordered dither pattern fade"),
        .init(id: 21, name: "Push Left", quick: false, blurb: "New cover pushes the old one out"),
        .init(id: 22, name: "Crossfade", quick: false, blurb: "Smooth blend"),
        .init(id: 23, name: "Card Flip", quick: false, blurb: "The whole cover flips like a card"),
        .init(id: 24, name: "Tile Flip Wave", quick: false, blurb: "Tiles flip in a diagonal wave"),
        .init(id: 25, name: "Block Drop", quick: false, blurb: "Blocks fall into place, bottom row first"),
        .init(id: 26, name: "Melt", quick: false, blurb: "The old cover drips away in columns"),
        .init(id: 27, name: "Zoom Punch", quick: false, blurb: "Zooms in with a small overshoot"),
        .init(id: 28, name: "Corner Peel", quick: false, blurb: "Peels back from a corner"),
        .init(id: 29, name: "Shatter", quick: false, blurb: "Breaks into shards"),
        .init(id: 30, name: "Cube Turn", quick: false, blurb: "Rotates like a cube"),
        .init(id: 31, name: "Jelly Drop", quick: false, blurb: "Wobbly drop from the top"),
        .init(id: 32, name: "Tile Spin", quick: false, blurb: "Tiles spin over in a wave"),
        .init(id: 33, name: "Infinite Zoom", quick: false, blurb: "Old cover zooms away, new one zooms in"),
        .init(id: 34, name: "RGB Split", quick: false, blurb: "Colour channels slide apart"),
        .init(id: 35, name: "Accordion", quick: false, blurb: "Folds open in alternating strips"),
        .init(id: 36, name: "Ink Bleed", quick: false, blurb: "Ink spreads from a few drops"),
        .init(id: 37, name: "Crack Split", quick: false, blurb: "Splits along a jagged crack"),
        .init(id: 38, name: "Sand Pile", quick: false, blurb: "Grains pile up from the bottom"),
        .init(id: 39, name: "Halftone", quick: false, blurb: "A dot grid grows to fill the frame"),
        .init(id: 40, name: "Quick Iris", quick: true, blurb: "Fast round iris"),
        .init(id: 41, name: "Diamond Iris", quick: true, blurb: "Fast diamond-shaped iris"),
        .init(id: 42, name: "Heart Iris", quick: true, blurb: "Fast heart-shaped iris"),
        .init(id: 43, name: "Clock Sweep", quick: true, blurb: "A clock hand sweeps the new cover in"),
        .init(id: 44, name: "Bow Tie", quick: true, blurb: "Bow-tie shape opens from the centre"),
        .init(id: 45, name: "Wind", quick: true, blurb: "Rows blow in from the right"),
        .init(id: 46, name: "Polka Dots", quick: true, blurb: "Dots grow, left to right"),
        .init(id: 47, name: "Rain Columns", quick: true, blurb: "Columns fall in like rain"),
        .init(id: 48, name: "Wave Wipe", quick: true, blurb: "A wavy edge sweeps across"),
        .init(id: 49, name: "Venetian H", quick: true, blurb: "Horizontal blinds open"),
        .init(id: 50, name: "Spiral In", quick: true, blurb: "Spirals in from the edge"),
        .init(id: 51, name: "Luma Wipe", quick: true, blurb: "Brightness-style soft wipe")
    ]

    /// Themes for the picker, so a whole family (e.g. everything that slides) can be switched at once.
    /// Every live transition is in exactly one group.
    struct Group: Identifiable {
        let name: String
        let ids: [Int]
        var id: String { name }
    }

    static let groups: [Group] = [
        Group(name: "Sliding & pushing", ids: [21, 18, 30, 23, 35]),
        Group(name: "Wipes & sweeps", ids: [0, 1, 2, 6, 7, 9, 28, 43, 48, 51]),
        Group(name: "Splits & blinds", ids: [12, 13, 14, 8, 49, 37]),
        Group(name: "Shapes & irises", ids: [3, 40, 41, 42, 44, 11, 50, 39, 46]),
        Group(name: "Blocks & tiles", ids: [4, 15, 17, 24, 25, 29, 32]),
        Group(name: "Fades & dissolves", ids: [22, 19, 20, 34, 36]),
        Group(name: "Drips & falls", ids: [26, 31, 38, 47, 45]),
        Group(name: "Zooms", ids: [27, 33])
    ]

    static func info(named name: String) -> TransitionInfo? {
        all.first { $0.name == name }
    }

    static func info(id: Int) -> TransitionInfo? {
        all.first { $0.id == id }
    }
}

// MARK: - Which transitions are switched on

/// The person's choice, stored as the indices they switched OFF (so a transition added later is on by default).
enum TransitionPrefs {
    static let storageKey = "disabledTransitions"

    static func disabledSet(from raw: String) -> Set<Int> {
        Set(raw.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) })
    }

    static func raw(from disabled: Set<Int>) -> String {
        disabled.sorted().map(String.init).joined(separator: ",")
    }

    static func enabledCount(disabledRaw: String) -> Int {
        let off = disabledSet(from: disabledRaw)
        return TransitionCatalog.all.filter { !off.contains($0.id) }.count
    }

    /// Bit i set = transition index i may be picked. All off means all on (the board never has nothing to draw).
    static func mask(disabledRaw: String) -> UInt64 {
        let off = disabledSet(from: disabledRaw)
        var mask: UInt64 = 0
        for t in TransitionCatalog.all where !off.contains(t.id) {
            mask |= (UInt64(1) << UInt64(t.id))
        }
        if mask == 0 {
            for t in TransitionCatalog.all { mask |= (UInt64(1) << UInt64(t.id)) }
        }
        return mask
    }

    static var currentMask: UInt64 {
        mask(disabledRaw: UserDefaults.standard.string(forKey: storageKey) ?? "")
    }
}

// MARK: - Preview engine

/// How an effect is drawn in the app. Most board effects are "reveal the new cover where a per-pixel
/// threshold has passed" (the board's own quick effects work exactly this way), so those share one mask
/// renderer; the rest move or fade whole covers. The app's versions are approximations of the board's.
enum TransitionMode {
    case threshold, crossfade, push, cardStack, flip, cube, zoomPunch, infiniteZoom

    static func of(_ id: Int) -> TransitionMode {
        switch id {
        case 18: return .cardStack
        case 21: return .push
        case 22, 34: return .crossfade
        case 23: return .flip
        case 27: return .zoomPunch
        case 30: return .cube
        case 33: return .infiniteZoom
        default: return .threshold
        }
    }
}

private final class ThresholdGridCache {
    static let shared = ThresholdGridCache()
    private var grids: [Int: [Float]] = [:]
    private let lock = NSLock()

    func grid(for id: Int) -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        if let g = grids[id] { return g }
        let g = TransitionMaskMath.buildGrid(id: id)
        grids[id] = g
        return g
    }
}

enum TransitionMaskMath {
    /// Cells per side of the reveal mask.
    static let n = 48

    static func hash(_ a: Int, _ b: Int, _ s: Int = 0) -> Float {
        var h = UInt32(truncatingIfNeeded: a &* 374_761_393 &+ b &* 668_265_263 &+ s &* 2_147_483_647)
        h = (h ^ (h >> 13)) &* 1_274_126_177
        h ^= h >> 16
        return Float(h & 0xFFFF) / 65535
    }

    private static func frac(_ v: Float) -> Float { v - v.rounded(.down) }

    /// Raw reveal order for cell (ix, iy); x and y are the cell centre in 0...1. Normalised afterwards.
    private static func raw(id: Int, ix: Int, iy: Int, x: Float, y: Float) -> Float {
        let dx = x - 0.5
        let dy = y - 0.5
        let r = (dx * dx + dy * dy).squareRoot()
        switch id {
        case 0, 38: return (1 - y) * 0.85 + (id == 38 ? hash(ix, iy) * 0.15 : 0)
        case 1: return x
        case 2: return 1 - x
        case 3, 40: return r
        case 4:
            let checker = ((ix / 6) + (iy / 6)) % 2 == 0
            return (checker ? 0 : 0.5) + hash(ix, iy) * 0.5
        case 6, 28: return (x + (id == 28 ? 1 - y : y)) / 2
        case 7: return 1 - (x + y) / 2
        case 8: return frac(x * 10)
        case 9: return min(x, 1 - x) + min(y, 1 - y)
        case 11: return max(abs(dx), abs(dy))
        case 12: return abs(dy)
        case 13, 14: return abs(dx)
        case 15: return hash(ix / 3, iy / 3)
        case 17: return Float((ix / 6) + (iy / 6)) * 0.07 + hash(ix / 6, iy / 6) * 0.25
        case 19: return hash(ix, iy)
        case 20:
            let bayer: [Int] = [0, 32, 8, 40, 2, 34, 10, 42, 48, 16, 56, 24, 50, 18, 58, 26,
                                12, 44, 4, 36, 14, 46, 6, 38, 60, 28, 52, 20, 62, 30, 54, 22,
                                3, 35, 11, 43, 1, 33, 9, 41, 51, 19, 59, 27, 49, 17, 57, 25,
                                15, 47, 7, 39, 13, 45, 5, 37, 63, 31, 55, 23, 61, 29, 53, 21]
            return Float(bayer[(iy % 8) * 8 + (ix % 8)]) / 64
        case 24, 32: return Float((ix / 8) + (iy / 8)) * 0.1 + hash(ix / 8, iy / 8, id) * 0.2 + r * 0.15
        case 25: return (1 - y) * 0.7 + hash(ix / 8, iy / 8) * 0.3
        case 26, 31: return y * 0.6 + hash(ix / 2, 0, id) * 0.4
        case 29: return hash(ix / 6, iy / 6, 3) * 0.7 + r * 0.3
        case 35: return (Int(y * 8) % 2 == 0) ? frac(y * 8) : 1 - frac(y * 8)
        case 36:
            let seeds: [(Float, Float)] = [(0.25, 0.3), (0.7, 0.2), (0.5, 0.75)]
            var best: Float = 10
            for s in seeds {
                let ddx = x - s.0
                let ddy = y - s.1
                best = min(best, (ddx * ddx + ddy * ddy).squareRoot())
            }
            return best + hash(ix, iy) * 0.05
        case 37:
            let crack = 0.5 + 0.08 * sin(y * 12) + 0.04 * sin(y * 29)
            return abs(x - crack)
        case 39:
            let fx = frac(x * 12) - 0.5
            let fy = frac(y * 12) - 0.5
            return (fx * fx + fy * fy).squareRoot()
        case 41: return abs(dx) + abs(dy)
        case 42:
            // Heart implicit curve, as in the firmware: find the scale s where (u/s, v/s) is on the heart.
            let u = dx * 2 * 1.25
            let v = -dy * 2 * 1.25 + 0.15
            var lo: Float = 0
            var hi: Float = 3
            for _ in 0..<16 {
                let s = (lo + hi) / 2
                let a = u / s
                let b = v / s
                let q = a * a + b * b - 1
                if q * q * q - a * a * b * b * b <= 0 { hi = s } else { lo = s }
            }
            return hi
        case 43:
            var ang = atan2(dx, -dy)
            if ang < 0 { ang += 2 * Float.pi }
            return ang
        case 44: return (0.5 - abs(dx)) + abs(dy) * 0.6
        case 45: return (1 - x) * 0.6 + hash(iy / 2, 11) * 0.4
        case 46:
            let cx = (Float(ix / 6) * 6 + 3) / Float(n)
            let cy = (Float(iy / 6) * 6 + 3) / Float(n)
            let ddx = x - cx
            let ddy = y - cy
            return x * 0.5 + (ddx * ddx + ddy * ddy).squareRoot() * 2.5
        case 47: return y * 0.55 + hash(ix / 2, 12) * 0.52
        case 48: return x * 0.8 + 0.2 * (0.5 + 0.5 * sin(y * 4 * Float.pi))
        case 49: return frac(y * 12)
        case 50:
            var ang = atan2(dx, -dy)
            if ang < 0 { ang += 2 * Float.pi }
            return (1 - r) * 0.8 + (ang / (2 * Float.pi)) * 0.2
        case 51: return x * 0.5 + 0.5 * (0.5 + 0.5 * sin(x * 9) * cos(y * 7))
        default: return y
        }
    }

    /// n*n reveal times, normalised so the first cell is 0 and the last is 1.
    static func buildGrid(id: Int) -> [Float] {
        var g = [Float](repeating: 0, count: n * n)
        var lo = Float.greatestFiniteMagnitude
        var hi = -Float.greatestFiniteMagnitude
        for iy in 0..<n {
            for ix in 0..<n {
                let v = raw(id: id, ix: ix, iy: iy, x: (Float(ix) + 0.5) / Float(n), y: (Float(iy) + 0.5) / Float(n))
                g[iy * n + ix] = v
                lo = min(lo, v)
                hi = max(hi, v)
            }
        }
        let span = max(0.0001, hi - lo)
        for i in 0..<g.count { g[i] = (g[i] - lo) / span }
        return g
    }

    static func grid(for id: Int) -> [Float] {
        ThresholdGridCache.shared.grid(for: id)
    }
}

/// Mask that is opaque where the new cover has been revealed at `progress` (0...1).
struct ThresholdMask: View {
    let id: Int
    let progress: CGFloat

    var body: some View {
        let grid = TransitionMaskMath.grid(for: id)
        let p = Float(progress)
        return Canvas { context, size in
            let n = TransitionMaskMath.n
            let cw = size.width / CGFloat(n)
            let ch = size.height / CGFloat(n)
            var path = Path()
            for iy in 0..<n {
                for ix in 0..<n where grid[iy * n + ix] <= p {
                    path.addRect(CGRect(x: CGFloat(ix) * cw - 0.25, y: CGFloat(iy) * ch - 0.25,
                                        width: cw + 0.5, height: ch + 0.5))
                }
            }
            context.fill(path, with: .color(.white))
        }
    }
}

/// Draws `old` turning into `new` using transition `id` at `progress` (0 = all old, 1 = all new).
struct TransitionStage<Old: View, New: View>: View {
    let id: Int
    let progress: CGFloat
    let old: Old
    let new: New

    init(id: Int, progress: CGFloat, @ViewBuilder old: () -> Old, @ViewBuilder new: () -> New) {
        self.id = id
        self.progress = progress
        self.old = old()
        self.new = new()
    }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let p = max(0, min(1, progress))
            ZStack {
                switch TransitionMode.of(id) {
                case .threshold:
                    old.frame(width: w, height: h)
                    new.frame(width: w, height: h).mask(ThresholdMask(id: id, progress: p))
                case .crossfade:
                    old.frame(width: w, height: h)
                    new.frame(width: w, height: h).opacity(Double(p))
                case .push:
                    old.frame(width: w, height: h).offset(x: -w * p)
                    new.frame(width: w, height: h).offset(x: w * (1 - p))
                case .cardStack:
                    old.frame(width: w, height: h)
                    new.frame(width: w, height: h)
                        .shadow(color: .black.opacity(0.35), radius: 8, x: -4, y: 0)
                        .offset(x: w * (1 - p))
                case .flip:
                    if p < 0.5 {
                        old.frame(width: w, height: h)
                            .rotation3DEffect(.degrees(Double(p) * 180), axis: (x: 0, y: 1, z: 0), perspective: 0.5)
                    } else {
                        new.frame(width: w, height: h)
                            .rotation3DEffect(.degrees(Double(p - 1) * 180), axis: (x: 0, y: 1, z: 0), perspective: 0.5)
                    }
                case .cube:
                    old.frame(width: w, height: h)
                        .rotation3DEffect(.degrees(-90 * Double(p)), axis: (x: 0, y: 1, z: 0),
                                          anchor: .trailing, perspective: 0.4)
                        .offset(x: -w * p)
                    new.frame(width: w, height: h)
                        .rotation3DEffect(.degrees(90 * Double(1 - p)), axis: (x: 0, y: 1, z: 0),
                                          anchor: .leading, perspective: 0.4)
                        .offset(x: w * (1 - p))
                case .zoomPunch:
                    // Ease-out-back: overshoots a little before settling at 1.
                    let c: CGFloat = 1.70158
                    let t = p - 1
                    let eased = 1 + (c + 1) * t * t * t + c * t * t
                    old.frame(width: w, height: h)
                    new.frame(width: w, height: h)
                        .scaleEffect(max(0.01, eased))
                        .opacity(Double(min(1, p * 3)))
                case .infiniteZoom:
                    old.frame(width: w, height: h)
                        .scaleEffect(1 + 2 * p)
                        .opacity(Double(1 - p))
                    new.frame(width: w, height: h)
                        .scaleEffect(0.4 + 0.6 * p)
                        .opacity(Double(p))
                }
            }
            .frame(width: w, height: h)
            .clipped()
        }
    }
}

// MARK: - Sample covers + looping preview (for the picker)

/// A stand-in "cover" so a transition can be seen without a real song. Two variants alternate.
struct SampleCover: View {
    let variant: Int

    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height)
            ZStack {
                LinearGradient(
                    colors: variant == 0
                        ? [Color(red: 0.98, green: 0.55, blue: 0.25), Color(red: 0.85, green: 0.2, blue: 0.45)]
                        : [Color(red: 0.2, green: 0.75, blue: 0.75), Color(red: 0.25, green: 0.2, blue: 0.7)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                Circle()
                    .fill(Color.white.opacity(0.25))
                    .frame(width: s * 0.7, height: s * 0.7)
                    .offset(x: variant == 0 ? -s * 0.15 : s * 0.15, y: s * 0.1)
                Text(variant == 0 ? "A" : "B")
                    .font(.system(size: s * 0.5, weight: .heavy, design: .rounded))
                    .foregroundColor(.white.opacity(0.9))
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }
}

/// Plays transition `id` between the two sample covers forever (A to B, then B to A, ...).
struct LoopingTransitionPreview: View {
    let id: Int
    var duration: Double = 1.1
    private let hold = 0.55

    var body: some View {
        TimelineView(.animation) { timeline in
            let period = duration + hold * 2
            let t = timeline.date.timeIntervalSinceReferenceDate
            let cycle = Int((t / period).rounded(.down))
            let local = t - Double(cycle) * period
            let raw = (local - hold) / duration
            let progress = CGFloat(max(0, min(1, raw)))
            let fromA = cycle % 2 == 0
            TransitionStage(id: id, progress: progress) {
                SampleCover(variant: fromA ? 0 : 1)
            } new: {
                SampleCover(variant: fromA ? 1 : 0)
            }
        }
    }
}
