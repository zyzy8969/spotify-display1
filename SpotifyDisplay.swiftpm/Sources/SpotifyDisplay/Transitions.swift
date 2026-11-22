import SwiftUI
import UIKit

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
    /// Every live transition (retired indices 5, 10, 16, 75-80 and 92 are not listed), in header-index order.
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
        .init(id: 51, name: "Luma Wipe", quick: true, blurb: "Brightness-style soft wipe"),
        // BLE_PROTOCOL 1.15 (build 46). 75-80 and 92 are retired (not listed).
        .init(id: 52, name: "Wipe Down", quick: true, blurb: "Reveals from the top edge downward"),
        .init(id: 53, name: "Iris Close", quick: true, blurb: "A ring closes in to the centre"),
        .init(id: 54, name: "Diamond Close", quick: true, blurb: "A diamond closes in to the centre"),
        .init(id: 55, name: "Heart Close", quick: true, blurb: "The old cover shrinks to a heart"),
        .init(id: 56, name: "Clock Reverse", quick: true, blurb: "The clock hand sweeps anticlockwise"),
        .init(id: 57, name: "Bow Tie Close", quick: true, blurb: "Bow tie closes from the sides"),
        .init(id: 58, name: "Wind Reverse", quick: true, blurb: "Rows blow in from the left"),
        .init(id: 59, name: "Polka Dots Reverse", quick: true, blurb: "Dots grow, right to left"),
        .init(id: 60, name: "Rain Rise", quick: true, blurb: "Columns rise up from the bottom"),
        .init(id: 61, name: "Wave Wipe Reverse", quick: true, blurb: "A wavy edge sweeps right to left"),
        .init(id: 62, name: "Spiral Out", quick: true, blurb: "Spirals out from the centre"),
        .init(id: 63, name: "Box Close", quick: true, blurb: "A square closes in to the centre"),
        .init(id: 64, name: "Split Close H", quick: true, blurb: "Top and bottom close to the middle"),
        .init(id: 65, name: "Split Close V", quick: true, blurb: "Left and right close to the middle"),
        .init(id: 66, name: "Diagonal Up", quick: true, blurb: "Wipes from bottom-left to top-right"),
        .init(id: 67, name: "Diagonal Down Left", quick: true, blurb: "Wipes from top-right to bottom-left"),
        .init(id: 68, name: "Halftone Shrink", quick: true, blurb: "The old cover shrinks into dots"),
        .init(id: 69, name: "Luma Wipe Reverse", quick: true, blurb: "Highlights arrive first, shadows last"),
        .init(id: 70, name: "Plus Wipe", quick: true, blurb: "A plus sign opens from the centre"),
        .init(id: 71, name: "Plus Close", quick: true, blurb: "Corners close in to a plus"),
        .init(id: 72, name: "Wheel", quick: true, blurb: "Four spokes sweep round"),
        .init(id: 73, name: "Random Bars", quick: true, blurb: "Horizontal bars pop in at random"),
        .init(id: 74, name: "Random Bars V", quick: true, blurb: "Vertical bars pop in at random"),
        .init(id: 81, name: "Push Right", quick: false, blurb: "New cover pushes the old one out to the right"),
        .init(id: 82, name: "Card Stack Left", quick: false, blurb: "New cover slides over from the left"),
        .init(id: 83, name: "Cube Turn Reverse", quick: false, blurb: "Cube rotates the other way"),
        .init(id: 84, name: "Corner Peel Reverse", quick: false, blurb: "Peels back from the other corner"),
        .init(id: 85, name: "Accordion Reverse", quick: false, blurb: "Folds into the left edge"),
        .init(id: 86, name: "Block Rise", quick: false, blurb: "Blocks fly up into place, top row first"),
        .init(id: 87, name: "Melt Up", quick: false, blurb: "The old cover drips upward"),
        .init(id: 88, name: "Jelly Rise", quick: false, blurb: "Wobbly rise from the bottom"),
        .init(id: 89, name: "Zoom Out", quick: false, blurb: "The old cover shrinks away into the centre"),
        .init(id: 90, name: "Infinite Zoom Out", quick: false, blurb: "Camera pulls back out of the old cover"),
        .init(id: 91, name: "CRT Off", quick: false, blurb: "Old TV switches off to a line, new one switches on"),
        .init(id: 93, name: "Neon Scan", quick: false, blurb: "Cyan scan line with a glowing grid"),
        .init(id: 94, name: "Glass Sweep", quick: false, blurb: "Glossy Aero-style glint sweeps across"),
        .init(id: 95, name: "Pixelate", quick: false, blurb: "Breaks into big pixels and sharpens back"),
        .init(id: 96, name: "VHS Glitch", quick: false, blurb: "Tape-tracking tears and colour fringes"),
        .init(id: 97, name: "Cube Up", quick: false, blurb: "Cube rolls the old cover away upward"),
        .init(id: 98, name: "Cube Down", quick: false, blurb: "Cube rolls the old cover away downward"),
        // Slideshow set (PowerPoint 2003 / 2010, Google Slides)
        .init(id: 99, name: "Comb Horizontal", quick: false, blurb: "Alternate strips slide in from left and right"),
        .init(id: 100, name: "Comb Vertical", quick: false, blurb: "Alternate strips slide in from top and bottom"),
        .init(id: 101, name: "Cover Down", quick: false, blurb: "New cover drops down over the old one"),
        .init(id: 102, name: "Uncover Left", quick: false, blurb: "Old cover slides off left, revealing the new one"),
        .init(id: 103, name: "Uncover Down", quick: false, blurb: "Old cover slides down and out"),
        .init(id: 104, name: "Fade Through Black", quick: false, blurb: "Fade out to black, then fade up"),
        .init(id: 105, name: "Newsflash", quick: false, blurb: "New cover spins in from the centre, twice round"),
        .init(id: 106, name: "Strips", quick: true, blurb: "Stair-step blocks wipe from the top-left"),
        .init(id: 107, name: "Wedge", quick: true, blurb: "Two hands sweep down both sides from 12 o'clock"),
        .init(id: 108, name: "Checkerboard Across", quick: true, blurb: "Checker squares fill left to right, staggered"),
        .init(id: 109, name: "Honeycomb", quick: true, blurb: "Hexagons pop in with a warm edge"),
        .init(id: 110, name: "Glitter", quick: true, blurb: "Diamonds sparkle in, left to right"),
        .init(id: 111, name: "Shred", quick: false, blurb: "Old cover cut into strips that slide apart"),
        .init(id: 112, name: "Gallery", quick: false, blurb: "Covers glide past on a reflective floor"),
        .init(id: 113, name: "Doors", quick: false, blurb: "Two doors swing open toward you"),
        .init(id: 114, name: "Ripple", quick: false, blurb: "A water ripple spreads from the centre"),
        .init(id: 115, name: "Flash", quick: false, blurb: "Camera-flash white-out into the new cover"),
        .init(id: 116, name: "Fly Through", quick: false, blurb: "Fly through the old cover into the new one")
    ]

    /// Themes for the picker, so a whole family (e.g. everything that slides) can be switched at once.
    /// Every live transition is in exactly one group.
    struct Group: Identifiable {
        let name: String
        let ids: [Int]
        var id: String { name }
    }

    static let groups: [Group] = [
        Group(name: "Y2K tech", ids: [91, 93, 94, 95, 96]),
        Group(name: "PowerPoint & Slides", ids: [99, 100, 101, 102, 103, 104, 105, 106, 107, 108,
                                                 109, 110, 111, 112, 113, 114, 115, 116]),
        Group(name: "Sliding & pushing", ids: [21, 81, 18, 82, 30, 83, 97, 98, 23, 35, 85]),
        Group(name: "Wipes & sweeps", ids: [0, 52, 1, 2, 6, 7, 66, 67, 9, 28, 84, 43, 56, 72, 48, 61, 51, 69]),
        Group(name: "Splits & blinds", ids: [12, 64, 13, 65, 14, 8, 49, 37, 73, 74]),
        Group(name: "Shapes & irises", ids: [3, 40, 53, 41, 54, 42, 55, 44, 57, 11, 63, 70, 71,
                                             50, 62, 39, 68, 46, 59]),
        Group(name: "Blocks & tiles", ids: [4, 15, 17, 24, 25, 86, 29, 32]),
        Group(name: "Fades & dissolves", ids: [22, 19, 20, 34, 36]),
        Group(name: "Drips & falls", ids: [26, 87, 31, 88, 38, 47, 60, 45, 58]),
        Group(name: "Zooms", ids: [27, 89, 33, 90])
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

    /// 128-bit enabled mask (BLE_PROTOCOL 1.15) as two 64-bit halves. Bit i set = transition index i
    /// may be picked. Nothing on (bit 127 aside) = the board shows new covers at once, no transition.
    struct Mask128: Equatable {
        var lo: UInt64 = 0
        var hi: UInt64 = 0
        /// Bit 127: tells 1.15 firmware the upper half is real (a 1.12-1.14 app sends zeros there).
        static let extendedFlag: UInt64 = 1 << 63

        mutating func set(_ i: Int) {
            if i < 64 { lo |= UInt64(1) << UInt64(i) } else { hi |= UInt64(1) << UInt64(i - 64) }
        }

        func contains(_ i: Int) -> Bool {
            i < 64 ? (lo >> UInt64(i)) & 1 == 1 : (hi >> UInt64(i - 64)) & 1 == 1
        }
    }

    static func mask(disabledRaw: String) -> Mask128 {
        let off = disabledSet(from: disabledRaw)
        var mask = Mask128()
        for t in TransitionCatalog.all where !off.contains(t.id) { mask.set(t.id) }
        mask.hi |= Mask128.extendedFlag
        return mask
    }

    static var currentMask: Mask128 {
        mask(disabledRaw: UserDefaults.standard.string(forKey: storageKey) ?? "")
    }
}

// MARK: - Transition speeds (BLE_PROTOCOL 1.14)

/// Per-transition speed and the "random speed" switch. Every transition runs at its normal speed (1x)
/// unless the person sets one; with random speed on (the default), each draw of a transition left at
/// normal picks a speed between 0.4x and 1.3x on the board (owner's range, 2026-11-22).
enum TransitionSpeeds {
    /// Only the transitions the person changed: "id:percent" pairs, e.g. "22:150,35:60".
    static let storageKey = "transitionSpeeds"
    static let randomKey = "transitionSpeedRandom"
    static let minPercent = 40
    static let maxPercent = 130
    static let normal = 100

    static func parse(_ raw: String) -> [Int: Int] {
        var out: [Int: Int] = [:]
        for pair in raw.split(separator: ",") {
            let parts = pair.split(separator: ":")
            guard parts.count == 2, let id = Int(parts[0]), let pct = Int(parts[1]) else { continue }
            out[id] = min(maxPercent, max(minPercent, pct))
        }
        return out
    }

    static func raw(from speeds: [Int: Int]) -> String {
        speeds.filter { $0.value != normal }
            .sorted { $0.key < $1.key }
            .map { "\($0.key):\($0.value)" }
            .joined(separator: ",")
    }

    static var current: [Int: Int] {
        parse(UserDefaults.standard.string(forKey: storageKey) ?? "")
    }

    /// On unless the person switched it off.
    static let randomDefault = true
    static var randomOn: Bool {
        UserDefaults.standard.object(forKey: randomKey) as? Bool ?? randomDefault
    }

    /// "1.5x", "0.75x", "1x".
    static func label(_ percent: Int) -> String {
        let v = Double(percent) / 100
        var s = String(format: "%.2f", v)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s + "x"
    }

    /// The 1.14 write: magic, flags (bit 0 = random), then one byte per header index
    /// (0 = default, otherwise percent): 0-51 for 1.14 boards, 0-116 for 1.15 (`CAPS:t128`).
    static let magic = UInt32(0xCAC4E1EC)
    static let slots = 52
    static let slots128 = 117

    static func packet(speeds: [Int: Int], random: Bool, slots: Int = TransitionSpeeds.slots) -> Data {
        var data = Data()
        withUnsafeBytes(of: magic.littleEndian) { data.append(contentsOf: $0) }
        data.append(random ? 1 : 0)
        for i in 0..<slots {
            data.append(UInt8(clamping: speeds[i] ?? 0))
        }
        return data
    }
}

// MARK: - Approximate engine (fallback for firmware older than BLE_PROTOCOL 1.13)

/// Only `ArtStage` uses this now, for boards that do not announce `TRANSITION_START`: the picker,
/// the Live page and the 1.13 cover mirror draw the real effect with `TransitionRenderer`.
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


// MARK: - Sample covers + looping preview (picker, Live page)

/// A stand-in "cover" so a transition can be seen without a real song. Two variants. Shown as is
/// while a preview is still rendering.
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

/// The two sample covers as 240x240 LE RGB565 frames, drawn with Core Graphics (off the main thread).
enum SampleCoverArt {
    static func frame(variant: Int) -> Data? {
        let side = CGFloat(TransitionRenderer.side)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format)
        let image = renderer.image { ui in
            let cg = ui.cgContext
            let colors: [UIColor] = variant == 0
                ? [UIColor(red: 0.98, green: 0.55, blue: 0.25, alpha: 1), UIColor(red: 0.85, green: 0.2, blue: 0.45, alpha: 1)]
                : [UIColor(red: 0.2, green: 0.75, blue: 0.75, alpha: 1), UIColor(red: 0.25, green: 0.2, blue: 0.7, alpha: 1)]
            let cgColors = colors.map { $0.cgColor } as CFArray
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: cgColors, locations: [0, 1]) {
                cg.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: side, y: side), options: [])
            }
            let d = side * 0.7
            let cx = side / 2 + (variant == 0 ? -side * 0.15 : side * 0.15)
            let cy = side / 2 + side * 0.1
            cg.setFillColor(UIColor(white: 1, alpha: 0.25).cgColor)
            cg.fillEllipse(in: CGRect(x: cx - d / 2, y: cy - d / 2, width: d, height: d))
            let font = UIFont.systemFont(ofSize: side * 0.5, weight: .heavy)
            let text = NSAttributedString(string: variant == 0 ? "A" : "B", attributes: [
                .font: font,
                .foregroundColor: UIColor(white: 1, alpha: 0.9)
            ])
            let size = text.size()
            text.draw(at: CGPoint(x: (side - size.width) / 2, y: (side - size.height) / 2))
        }
        guard let cgImage = image.cgImage else { return nil }
        return TransitionRenderer.rgb565(from: cgImage)
    }
}

/// Real previews: every transition rendered A to B by the board's own code (`TransitionRenderer`),
/// at preview size, on the renderer's queue, and kept for the rows most recently on screen.
/// A = the current song's cover, B = the next song in the Spotify queue (`refreshCovers`); either one
/// falls back to its sample cover when missing. Until real covers are known (and while they render)
/// the sample previews show, then each row swaps to the real-cover render when it is ready.
@MainActor
final class TransitionPreviewStore: ObservableObject {
    static let shared = TransitionPreviewStore()

    @Published private(set) var previews: [Int: RenderedTransition] = [:]
    /// The cover pair each kept preview was rendered from (`pairGen` at the time).
    private var previewGen: [Int: UInt64] = [:]
    /// Renders running, with the pair they render.
    private var inFlight: [Int: UInt64] = [:]
    /// Least recently requested first.
    private var recent: [Int] = []
    /// About 1.7 MB per preview (30 frames of 120x120).
    private let capacity = 12
    private var samplesTask: Task<[Data]?, Never>?

    /// Real covers as 240x240 LE RGB565 (nil = use the sample). Bumping `pairGen` invalidates previews.
    private var coverA: Data?
    private var coverB: Data?
    private var pairGen: UInt64 = 0

    /// Gives the next queued song's cover (JPEG), or nil. Set by `SpotifyManager.startMonitoring`.
    var nextCoverSource: (@MainActor () async -> Data?)?
    /// The current-song frame the last applied refresh used, to tell a real song change from a
    /// repeated update of the same cover (the board frame is set more than once per draw).
    private var lastCurrentFrame: Data?
    private var nextFetchPending = true
    private var refreshGen: UInt64 = 0

    private init() {}

    /// Re-reads A and B. `boardFrame` (the RGB565 on the board) wins; otherwise `albumArt` (JPEG) is
    /// converted the way a send would be. The queue is read when `opening` (the picker appeared) or
    /// when the current cover changed; otherwise the last B is kept. Cheap to call repeatedly.
    func refreshCovers(boardFrame: Data?, albumArt: Data?, opening: Bool) {
        if opening { nextFetchPending = true }
        refreshGen &+= 1
        let gen = refreshGen
        Task { @MainActor in
            var a: Data?
            if let frame = boardFrame, frame.count >= TransitionRenderer.frameBytes {
                a = frame
            } else if let jpeg = albumArt {
                a = await Self.frame(fromJPEG: jpeg)
            }
            guard gen == self.refreshGen else { return }
            let needNext = self.nextFetchPending || a != self.lastCurrentFrame
            var b = self.coverB
            if needNext {
                b = nil
                if let source = self.nextCoverSource, let jpeg = await source() {
                    b = await Self.frame(fromJPEG: jpeg)
                }
                guard gen == self.refreshGen else { return }
                self.nextFetchPending = false
            }
            self.lastCurrentFrame = a
            // Same picture both sides (next song is on the same album): a transition would show
            // nothing, so B goes back to its sample.
            if let a, let bb = b, a == bb { b = nil }
            self.setCovers(a: a, b: b)
        }
    }

    private static func frame(fromJPEG jpeg: Data) async -> Data? {
        await Task.detached(priority: .userInitiated) { () -> Data? in
            guard let frame = try? ImageProcessor.convertToRGB565(imageData: jpeg),
                  frame.count >= TransitionRenderer.frameBytes else { return nil }
            return frame
        }.value
    }

    private func setCovers(a: Data?, b: Data?) {
        guard a != coverA || b != coverB else { return }
        coverA = a
        coverB = b
        pairGen &+= 1
        // Re-render what was on screen most recently, newest first. The old previews stay up meanwhile.
        for id in recent.suffix(capacity).reversed() {
            request(id, touch: false)
        }
    }

    func request(_ id: Int) {
        request(id, touch: true)
    }

    private func request(_ id: Int, touch: Bool) {
        if touch {
            recent.removeAll { $0 == id }
            recent.append(id)
        }
        let gen = pairGen
        if previews[id] != nil, previewGen[id] == gen { return }
        if inFlight[id] == gen { return }
        inFlight[id] = gen
        let a = coverA
        let b = coverB
        Task { @MainActor in
            defer { if self.inFlight[id] == gen { self.inFlight[id] = nil } }
            var old = a
            var new = b
            if old == nil || new == nil {
                guard let samples = await self.sampleFrames(), samples.count == 2 else { return }
                if old == nil { old = samples[0] }
                if new == nil { new = samples[1] }
            }
            guard let oldFrame = old, let newFrame = new, gen == self.pairGen else { return }
            let seed = UInt32(truncatingIfNeeded: (id + 1) &* 40_503)
            let rendered = await TransitionRenderer.shared.render(
                index: id, old: oldFrame, new: newFrame, seed: seed, options: .preview
            )
            // A newer pair arrived meanwhile: its own render replaces this one.
            guard !rendered.isEmpty, gen == self.pairGen else { return }
            self.previews[id] = rendered
            self.previewGen[id] = gen
            self.evictIfNeeded()
        }
    }

    private func sampleFrames() async -> [Data]? {
        if samplesTask == nil {
            samplesTask = Task.detached(priority: .userInitiated) { () -> [Data]? in
                guard let a = SampleCoverArt.frame(variant: 0), let b = SampleCoverArt.frame(variant: 1) else {
                    return nil
                }
                return [a, b]
            }
        }
        guard let task = samplesTask else { return nil }
        return await task.value
    }

    private func evictIfNeeded() {
        while previews.count > capacity, let oldest = recent.first {
            recent.removeFirst()
            previews[oldest] = nil
            previewGen[oldest] = nil
        }
    }
}

/// Plays transition `id` from cover A to B (the current and next song, or the samples), on a loop:
/// hold A, the board's effect, hold B.
/// Frames come precomputed from `TransitionPreviewStore`; each tick only picks one.
struct LoopingTransitionPreview: View {
    let id: Int
    /// Kept for callers; the real render's own length is used.
    var duration: Double = 1.1
    /// Playback speed (1 = normal). The 1x render is played faster or slower, so moving a speed
    /// slider changes the example at once without rendering it again.
    var speed: Double = 1
    @ObservedObject private var store = TransitionPreviewStore.shared
    private let hold = 0.55

    var body: some View {
        Group {
            if let rendered = store.previews[id], !rendered.isEmpty {
                TimelineView(.animation) { timeline in
                    let rate = max(0.25, speed)
                    let length = max(0.1, rendered.duration / rate)
                    let period = length + hold * 2
                    let t = timeline.date.timeIntervalSinceReferenceDate
                    let local = (t.truncatingRemainder(dividingBy: period) - hold) * rate
                    if let frame = rendered.frame(at: local) {
                        Image(decorative: frame, scale: 1)
                            .resizable()
                            .interpolation(.medium)
                    } else {
                        SampleCover(variant: 0)
                    }
                }
            } else {
                SampleCover(variant: 0)
            }
        }
        .onAppear { store.request(id) }
        .onChange(of: id) { newID in store.request(newID) }
    }
}
