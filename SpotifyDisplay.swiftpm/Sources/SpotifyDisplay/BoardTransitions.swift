import CoreGraphics
import Foundation
import UIKit

// A port of the firmware's transitions (`src/main.cpp`, `runTransition`) so the app's cover plays
// the same one the keychain does. Each transition is recomputed here on a 240x240 pixel buffer,
// from the same old and new covers, with the same frame structure, so the app shows the board's
// frames rather than an imitation. Only the timing is estimated: see `BoardTransition.duration`.
//
// Pixels are UInt32 with bytes R,G,B,X in memory (`px & 0xFF` = red). Keep this file in step with
// the firmware: a changed or new transition there needs the same change here.

// MARK: - Transition list

/// The firmware's `TransitionType`. `rawValue` is the byte the 5-byte image header carries and
/// `name` matches `getTransitionName()`, which the board reports as `TRANSITION:<name>` after a
/// cache hit. Slots 5, 10 and 16 are retired on the board and never used.
enum BoardTransition: UInt8, CaseIterable {
    case wipeUp = 0, wipeRight = 1, wipeLeft = 2, circular = 3, checkerboard = 4
    case diagonal = 6, diagonalInverse = 7, venetianV = 8, fourCorner = 9
    case zoomBlocks = 11, horizontalSplit = 12, verticalSplit = 13, barnDoors = 14, randomBlocks = 15
    case checkerCascade = 17, cardStack = 18, staticDissolve = 19, ditherFade = 20, pushLeft = 21
    case crossfade = 22, cardFlip = 23, tileFlip = 24, blockDrop = 25, melt = 26, zoomPunch = 27
    case cornerPeel = 28, shatter = 29, cubeTurn = 30, jellyDrop = 31, tileSpin = 32
    case infiniteZoom = 33, rgbSplit = 34, accordion = 35, inkBleed = 36, crackSplit = 37
    case sandPile = 38, halftone = 39
    case quickIris = 40, diamondIris = 41, heartIris = 42, clockSweep = 43, bowTie = 44, wind = 45
    case polkaDots = 46, rainColumns = 47, waveWipe = 48, venetianH = 49, spiralIn = 50, lumaWipe = 51

    var name: String {
        switch self {
        case .wipeUp: return "Wipe Up"
        case .wipeRight: return "Wipe Right"
        case .wipeLeft: return "Wipe Left"
        case .circular: return "Circular"
        case .checkerboard: return "Checkerboard"
        case .diagonal: return "Diagonal"
        case .diagonalInverse: return "Diagonal Inverse"
        case .venetianV: return "Venetian V"
        case .fourCorner: return "Four Corner"
        case .zoomBlocks: return "Zoom Blocks"
        case .horizontalSplit: return "Horizontal Split"
        case .verticalSplit: return "Vertical Split"
        case .barnDoors: return "Barn Doors"
        case .randomBlocks: return "Random Blocks"
        case .checkerCascade: return "Checker Cascade"
        case .cardStack: return "Card Stack"
        case .staticDissolve: return "Static Dissolve"
        case .ditherFade: return "Dither Fade"
        case .pushLeft: return "Push Left"
        case .crossfade: return "Crossfade"
        case .cardFlip: return "Card Flip"
        case .tileFlip: return "Tile Flip Wave"
        case .blockDrop: return "Block Drop"
        case .melt: return "Melt"
        case .zoomPunch: return "Zoom Punch"
        case .cornerPeel: return "Corner Peel"
        case .shatter: return "Shatter"
        case .cubeTurn: return "Cube Turn"
        case .jellyDrop: return "Jelly Drop"
        case .tileSpin: return "Tile Spin"
        case .infiniteZoom: return "Infinite Zoom"
        case .rgbSplit: return "RGB Split"
        case .accordion: return "Accordion"
        case .inkBleed: return "Ink Bleed"
        case .crackSplit: return "Crack Split"
        case .sandPile: return "Sand Pile"
        case .halftone: return "Halftone"
        case .quickIris: return "Quick Iris"
        case .diamondIris: return "Diamond Iris"
        case .heartIris: return "Heart Iris"
        case .clockSweep: return "Clock Sweep"
        case .bowTie: return "Bow Tie"
        case .wind: return "Wind"
        case .polkaDots: return "Polka Dots"
        case .rainColumns: return "Rain Columns"
        case .waveWipe: return "Wave Wipe"
        case .venetianH: return "Venetian H"
        case .spiralIn: return "Spiral In"
        case .lumaWipe: return "Luma Wipe"
        }
    }

    init?(name: String?) {
        guard let name, let match = Self.allCases.first(where: { $0.name == name }) else { return nil }
        self = match
    }

    /// The firmware's `QUICK_TRANSITIONS`: what it uses for new songs, which have already waited
    /// for their transfer. Cache hits use the full set (the board picks those itself).
    static let quickSet: [BoardTransition] = [
        .randomBlocks, .wipeUp, .venetianV, .checkerboard, .zoomBlocks, .verticalSplit,
        .quickIris, .diamondIris, .heartIris, .clockSweep, .bowTie, .wind, .polkaDots,
        .rainColumns, .waveWipe, .venetianH, .spiralIn, .lumaWipe
    ]

    /// A quick transition other than `previous`, like `drawImageWithQuickTransition()`.
    static func randomQuick(excluding previous: BoardTransition?) -> BoardTransition {
        quickSet.filter { $0 != previous }.randomElement() ?? .wipeUp
    }

    /// How long the board takes to draw it, in seconds. The first six are the firmware's measured
    /// times (comment on `QUICK_TRANSITIONS`); the rest are estimates from frame counts at the
    /// 40 MHz panel clock. Tune against the serial line `⚡ Processing: <name> draw <ms>ms`.
    var duration: Double {
        switch self {
        case .randomBlocks: return 0.13
        case .wipeUp, .venetianV: return 0.16
        case .checkerboard: return 0.24
        case .zoomBlocks: return 0.255
        case .verticalSplit: return 0.315
        case .quickIris, .diamondIris, .heartIris, .clockSweep, .bowTie, .wind, .polkaDots,
             .rainColumns, .waveWipe, .venetianH, .spiralIn, .lumaWipe:
            return 0.15
        case .wipeRight, .wipeLeft: return 0.45
        case .barnDoors: return 0.5
        case .horizontalSplit: return 0.55
        case .circular: return 0.6
        case .diagonal, .diagonalInverse, .fourCorner: return 0.7
        case .checkerCascade: return 0.3
        default:
            return Double(BoardTransitionRenderer.composedFrameCount(self)) * (isHeavy ? 0.022 : 0.016)
        }
    }

    /// Composed transitions with heavy per-pixel maths: slower frames on the board.
    private var isHeavy: Bool {
        switch self {
        case .cornerPeel, .shatter, .tileSpin, .sandPile, .halftone, .cubeTurn, .inkBleed: return true
        default: return false
        }
    }
}

// MARK: - Renderer

enum BoardTransitionRenderer {
    static let size = 240
    private static let count = size * size

    /// Every frame of `kind` from `old` to `new`, as the board composes them. The last frame is
    /// the new cover. Returns nil when a cover can't be rasterised. Run off the main thread.
    static func frames(_ kind: BoardTransition, from old: UIImage, to new: UIImage) -> [CGImage]? {
        guard let oldPx = pixels(of: old), let newPx = pixels(of: new) else { return nil }
        var out: [CGImage] = []
        var buffer = [UInt32](repeating: opaqueBlack, count: count)
        oldPx.withUnsafeBufferPointer { o in
            newPx.withUnsafeBufferPointer { n in
                buffer.withUnsafeMutableBufferPointer { pointer in
                    let dst = pointer  // a copy: the closure below may not capture the inout parameter
                    let emit: () -> Void = {
                        if let image = makeImage(UnsafeBufferPointer(dst)) { out.append(image) }
                    }
                    render(kind, old: o, new: n, into: dst, emit: emit)
                }
            }
        }
        if let final = makeImage(newPx) { out.append(final) }
        return out
    }

    /// Frame count of a frame-composed transition (for its duration estimate).
    static func composedFrameCount(_ kind: BoardTransition) -> Int {
        switch kind {
        case .cardStack: return 26
        case .staticDissolve, .ditherFade: return 18
        case .pushLeft, .cardFlip, .accordion: return 24
        case .crossfade: return 16
        case .tileFlip, .melt, .infiniteZoom: return 30
        case .blockDrop, .sandPile: return 36
        case .zoomPunch, .cubeTurn: return 26
        case .cornerPeel, .inkBleed, .halftone: return 28
        case .shatter, .tileSpin, .crackSplit: return 32
        case .jellyDrop: return 34
        case .rgbSplit: return 22
        default: return 10
        }
    }

    // MARK: Pixels

    static let opaqueBlack: UInt32 = 0xFF00_0000
    static let white: UInt32 = 0xFFFF_FFFF

    @inline(__always) static func pack(_ r: Int, _ g: Int, _ b: Int) -> UInt32 {
        0xFF00_0000 | (UInt32(b) << 16) | (UInt32(g) << 8) | UInt32(r)
    }

    /// `blend565`: k in 0...32, 0 = a, 32 = b.
    @inline(__always) static func blend(_ a: UInt32, _ b: UInt32, _ k: Int) -> UInt32 {
        let ik = 32 - k
        let r = ((Int(a & 0xFF) * ik) + (Int(b & 0xFF) * k)) >> 5
        let g = ((Int((a >> 8) & 0xFF) * ik) + (Int((b >> 8) & 0xFF) * k)) >> 5
        let bl = ((Int((a >> 16) & 0xFF) * ik) + (Int((b >> 16) & 0xFF) * k)) >> 5
        return pack(r, g, bl)
    }

    /// `shade565`: scale brightness by `f`.
    @inline(__always) static func shade(_ c: UInt32, _ f: Float) -> UInt32 {
        let k = max(0, Int(f * 256))
        let r = min(255, (Int(c & 0xFF) * k) >> 8)
        let g = min(255, (Int((c >> 8) & 0xFF) * k) >> 8)
        let b = min(255, (Int((c >> 16) & 0xFF) * k) >> 8)
        return pack(r, g, b)
    }

    @inline(__always) static func luma(_ c: UInt32) -> Float {
        Float(c & 0xFF) / 255 * 0.30 + Float((c >> 8) & 0xFF) / 255 * 0.59 + Float((c >> 16) & 0xFF) / 255 * 0.11
    }

    @inline(__always) static func cellHash(_ x: Int, _ y: Int) -> Int {
        var h = (UInt32(truncatingIfNeeded: x) &* 73_856_093) ^ (UInt32(truncatingIfNeeded: y) &* 19_349_663)
        h ^= h >> 13
        h = h &* 0x5BD1_E995
        h ^= h >> 15
        return Int(h & 0xFF)
    }

    @inline(__always) static func easeInOut(_ t: Float) -> Float {
        t < 0.5 ? 2 * t * t : 1 - (-2 * t + 2) * (-2 * t + 2) / 2
    }

    @inline(__always) static func clamp01(_ v: Float) -> Float { min(1, max(0, v)) }
    @inline(__always) static func clampPx(_ v: Int) -> Int { min(239, max(0, v)) }

    private static let rgbx = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)

    /// The cover at 240x240, aspect-filled like the app shows it.
    static func pixels(of image: UIImage) -> [UInt32]? {
        guard let cg = image.cgImage else { return nil }
        var px = [UInt32](repeating: opaqueBlack, count: count)
        let ok = px.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(
                data: raw.baseAddress, width: size, height: size, bitsPerComponent: 8,
                bytesPerRow: size * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: rgbx.rawValue
            ) else { return false }
            ctx.interpolationQuality = .high
            let w = CGFloat(cg.width), h = CGFloat(cg.height)
            let s = max(CGFloat(size) / w, CGFloat(size) / h)
            let dw = w * s, dh = h * s
            ctx.draw(cg, in: CGRect(x: (CGFloat(size) - dw) / 2, y: (CGFloat(size) - dh) / 2, width: dw, height: dh))
            return true
        }
        return ok ? px : nil
    }

    static func makeImage<C: Collection>(_ px: C) -> CGImage? where C.Element == UInt32 {
        let data = Array(px).withUnsafeBufferPointer { Data(buffer: $0) }
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(
            width: size, height: size, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: size * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: rgbx, provider: provider,
            decode: nil, shouldInterpolate: true, intent: .defaultIntent
        )
    }

    // MARK: Dispatch

    typealias Src = UnsafeBufferPointer<UInt32>
    typealias Dst = UnsafeMutableBufferPointer<UInt32>

    private static func render(_ kind: BoardTransition, old o: Src, new n: Src, into d: Dst, emit: () -> Void) {
        switch kind {
        case .wipeUp, .wipeRight, .wipeLeft, .circular, .checkerboard, .diagonal, .diagonalInverse,
             .venetianV, .fourCorner, .zoomBlocks, .horizontalSplit, .verticalSplit, .barnDoors,
             .randomBlocks, .checkerCascade:
            let (steps, total) = revealSteps(kind)
            playReveal(steps: steps, total: total, old: o, new: n, into: d, emit: emit)
        case .quickIris, .diamondIris, .heartIris, .clockSweep, .bowTie, .wind, .polkaDots,
             .rainColumns, .waveWipe, .venetianH, .spiralIn, .lumaWipe:
            quickMask(kind, old: o, new: n, into: d, emit: emit)
        case .cardStack: cardStack(o, n, d, emit)
        case .staticDissolve: maskDissolve(o, n, d, bayer: false, emit)
        case .ditherFade: maskDissolve(o, n, d, bayer: true, emit)
        case .pushLeft: pushLeft(o, n, d, emit)
        case .crossfade: crossfade(o, n, d, emit)
        case .cardFlip: cardFlip(o, n, d, emit)
        case .tileFlip: tileFlip(o, n, d, emit)
        case .blockDrop: blockDrop(o, n, d, emit)
        case .melt: melt(o, n, d, emit)
        case .zoomPunch: zoomPunch(o, n, d, emit)
        case .cornerPeel: cornerPeel(o, n, d, emit)
        case .shatter: shatter(o, n, d, emit)
        case .cubeTurn: cubeTurn(o, n, d, emit)
        case .jellyDrop: jellyDrop(o, n, d, emit)
        case .tileSpin: tileSpin(o, n, d, emit)
        case .infiniteZoom: infiniteZoom(o, n, d, emit)
        case .rgbSplit: rgbSplit(o, n, d, emit)
        case .accordion: accordion(o, n, d, emit)
        case .inkBleed: inkBleed(o, n, d, emit)
        case .crackSplit: crackSplit(o, n, d, emit)
        case .sandPile: sandPile(o, n, d, emit)
        case .halftone: halftone(o, n, d, emit)
        }
    }

    // MARK: Reveal transitions (draw the new cover onto the old one, piece by piece)

    /// The step at which the board's loop draws each pixel, and the number of steps.
    private static func revealSteps(_ kind: BoardTransition) -> ([Int32], Int) {
        var s = [Int32](repeating: 0, count: count)
        var total = 1
        func fill(_ f: (Int, Int) -> Int) {
            for y in 0..<size { for x in 0..<size { s[y * size + x] = Int32(f(x, y)) } }
        }
        switch kind {
        case .wipeUp:
            total = 240; fill { _, y in 239 - y }
        case .wipeRight:
            total = 120; fill { x, _ in x / 2 }
        case .wipeLeft:
            total = 120; fill { x, _ in (239 - x) / 2 }
        case .circular:
            // Radius 0, 3, 6 ... 168: drawn when r^2 <= d^2 < (r+3)^2.
            total = 57
            fill { x, y in
                let d2 = (x - 120) * (x - 120) + (y - 120) * (y - 120)
                var k = Int(Double(d2).squareRoot()) / 3
                while 9 * (k + 1) * (k + 1) <= d2 { k += 1 }
                while k > 0 && 9 * k * k > d2 { k -= 1 }
                return k
            }
        case .checkerboard:
            total = 4; fill { x, y in (x / 8 + y / 8) % 4 }
        case .diagonal:
            total = 120; fill { x, y in (x + y) / 4 }
        case .diagonalInverse:
            total = 120; fill { x, y in ((239 - x) + (239 - y)) / 4 }
        case .venetianV:
            total = 2; fill { x, _ in (x / 10) % 2 }
        case .fourCorner:
            total = 80
            fill { x, y in min(min(x + y, (239 - x) + y), min(x + (239 - y), (239 - x) + (239 - y))) / 3 }
        case .zoomBlocks:
            total = 9
            fill { x, y in max(abs((x / 16) * 16 + 8 - 120), abs((y / 16) * 16 + 8 - 120)) / 16 }
        case .horizontalSplit:
            total = 41; fill { _, y in y <= 120 ? (120 - y + 2) / 3 : (y - 120) / 3 }
        case .verticalSplit:
            total = 41; fill { x, _ in x <= 120 ? (120 - x + 2) / 3 : (x - 120) / 3 }
        case .barnDoors:
            total = 40; fill { _, y in y < 120 ? y / 3 : (239 - y) / 3 }
        case .randomBlocks:
            // The board shuffles with its own RNG; the app shuffles too (same look, its own order).
            total = 57
            var order = Array(0..<225)
            order.shuffle()
            var stepOfBlock = [Int](repeating: 0, count: 225)
            for (position, block) in order.enumerated() { stepOfBlock[block] = position / 4 }
            fill { x, y in stepOfBlock[(y / 16) * 15 + x / 16] }
        case .checkerCascade:
            total = 30
            fill { x, y in
                let tx = x / 8, ty = y / 8
                let thr = ((tx + ty) * 600) / 60 + (((tx + ty) & 1) != 0 ? 400 : 0)
                return min(29, thr * 30 / 1000)
            }
        default:
            break
        }
        return (s, total)
    }

    /// Up to 24 snapshots of the board's draw order: a pixel shows the new cover once its step
    /// has been drawn.
    private static func playReveal(steps: [Int32], total: Int, old o: Src, new n: Src, into d: Dst, emit: () -> Void) {
        let frames = min(total, 24)
        steps.withUnsafeBufferPointer { st in
            for f in 1...frames {
                let limit = Int32((f * total + frames - 1) / frames)
                for i in 0..<count { d[i] = st[i] < limit ? n[i] : o[i] }
                emit()
            }
        }
    }

    // MARK: Quick threshold masks (`drawQuickMask`)

    private static func quickThreshold(_ kind: BoardTransition, _ x: Int, _ y: Int) -> Float {
        let dx = Float(x) + 0.5 - 120, dy = Float(y) + 0.5 - 120
        let r = (dx * dx + dy * dy).squareRoot()
        var ang = atan2(dx, -dy)
        if ang < 0 { ang += 2 * .pi }
        switch kind {
        case .quickIris: return r
        case .diamondIris: return abs(dx) + abs(dy)
        case .heartIris:
            let u = dx / 120 * 1.25, v = -dy / 120 * 1.25 + 0.15
            var lo: Float = 0, hi: Float = 3
            for _ in 0..<16 {
                let s = (lo + hi) / 2, a = u / s, b = v / s, q = a * a + b * b - 1
                if q * q * q - a * a * b * b * b <= 0 { hi = s } else { lo = s }
            }
            return hi
        case .clockSweep: return ang
        case .bowTie: return (120 - abs(dx)) + abs(dy) * 0.6
        case .wind: return Float(240 - x) * 0.6 + Float(cellHash(y >> 1, 11)) * 0.4
        case .polkaDots:
            let cx = Float((x / 24) * 24 + 12), cy = Float((y / 24) * 24 + 12)
            return Float(x) * 0.5 + hypot(Float(x) + 0.5 - cx, Float(y) + 0.5 - cy) * 6
        case .rainColumns: return Float(y) * 0.55 + Float(cellHash(x >> 3, 12)) * 0.52
        case .waveWipe: return Float(x) * 0.8 + 48 * (0.5 + 0.5 * sin(Float(y) / 240 * 4 * .pi))
        case .venetianH: return Float(y % 20) * 9 + Float(y / 20) * 5
        case .spiralIn:
            let ring = min(min(x, y), min(239 - x, 239 - y)) / 8
            return Float(ring) + ang / (2 * .pi)
        default: return 0
        }
    }

    private static var quickMaps: [BoardTransition: [UInt8]] = [:]
    private static let quickMapsLock = NSLock()

    private static func quickMap(_ kind: BoardTransition) -> [UInt8] {
        quickMapsLock.lock()
        defer { quickMapsLock.unlock() }
        if let map = quickMaps[kind] { return map }
        var values = [Float](repeating: 0, count: count)
        var mn: Float = 1e9, mx: Float = -1e9
        for y in 0..<size {
            for x in 0..<size {
                let v = quickThreshold(kind, x, y)
                values[y * size + x] = v
                mn = min(mn, v); mx = max(mx, v)
            }
        }
        let span = mx - mn > 0 ? mx - mn : 1
        let map = values.map { UInt8(($0 - mn) / span * 250) }
        quickMaps[kind] = map
        return map
    }

    private static func quickMask(_ kind: BoardTransition, old o: Src, new n: Src, into d: Dst, emit: () -> Void) {
        // Luma Wipe: dark parts of the new cover arrive first, highlights last.
        let map: [UInt8] = kind == .lumaWipe
            ? (0..<count).map { UInt8(luma(n[$0]) * 250) }
            : quickMap(kind)
        map.withUnsafeBufferPointer { m in
            for f in 1...10 {
                let level = (f * 256) / 10
                for i in 0..<count { d[i] = Int(m[i]) < level ? n[i] : o[i] }
                emit()
            }
        }
    }

    // MARK: Frame-composed transitions

    private static func copy(_ s: Src, _ d: Dst) {
        for i in 0..<count { d[i] = s[i] }
    }

    private static func clear(_ d: Dst) {
        for i in 0..<count { d[i] = opaqueBlack }
    }

    private static func cardStack(_ o: Src, _ n: Src, _ d: Dst, _ emit: () -> Void) {
        let frames = 26
        for f in 1...frames {
            let x0 = Int((1 - easeInOut(Float(f) / Float(frames))) * 240)
            for y in 0..<size {
                let row = y * size
                for x in 0..<size { d[row + x] = x < x0 ? o[row + x] : n[row + x] }
                if x0 >= 3 { for x in (x0 - 3)..<x0 { d[row + x] = blend(d[row + x], opaqueBlack, 12) } }
            }
            emit()
        }
    }

    private static let bayer8: [[Int]] = [
        [0, 32, 8, 40, 2, 34, 10, 42], [48, 16, 56, 24, 50, 18, 58, 26],
        [12, 44, 4, 36, 14, 46, 6, 38], [60, 28, 52, 20, 62, 30, 54, 22],
        [3, 35, 11, 43, 1, 33, 9, 41], [51, 19, 59, 27, 49, 17, 57, 25],
        [15, 47, 7, 39, 13, 45, 5, 37], [63, 31, 55, 23, 61, 29, 53, 21]
    ]

    private static func maskDissolve(_ o: Src, _ n: Src, _ d: Dst, bayer: Bool, _ emit: () -> Void) {
        var thr = [Int](repeating: 0, count: count)
        for y in 0..<size {
            for x in 0..<size {
                thr[y * size + x] = bayer ? bayer8[y & 7][x & 7] * 4 : cellHash(x >> 1, y >> 1)
            }
        }
        let frames = 18
        for f in 1...frames {
            let level = (f * 256) / frames
            for i in 0..<count { d[i] = thr[i] < level ? n[i] : o[i] }
            emit()
        }
    }

    private static func pushLeft(_ o: Src, _ n: Src, _ d: Dst, _ emit: () -> Void) {
        let frames = 24
        for f in 1...frames {
            let off = Int(easeInOut(Float(f) / Float(frames)) * 240)
            for y in 0..<size {
                let row = y * size
                for x in 0..<size { d[row + x] = x < size - off ? o[row + x + off] : n[row + x - (size - off)] }
            }
            emit()
        }
    }

    private static func crossfade(_ o: Src, _ n: Src, _ d: Dst, _ emit: () -> Void) {
        let frames = 16
        for f in 1...frames {
            let k = Int(easeInOut(Float(f) / Float(frames)) * 32 + 0.5)
            for i in 0..<count { d[i] = blend(o[i], n[i], k) }
            emit()
        }
    }

    @inline(__always) private static func squashRow(_ d: Dst, _ s: Src, row y: Int, sx: Int, sw: Int, dx: Int, w: Int) {
        let base = y * size
        for x in 0..<w { d[base + dx + x] = s[base + sx + (x * sw) / w] }
    }

    private static func cardFlip(_ o: Src, _ n: Src, _ d: Dst, _ emit: () -> Void) {
        let frames = 24
        for f in 1...frames {
            let t = easeInOut(Float(f) / Float(frames))
            let w = max(1, Int(240 * abs(cos(Float.pi * t))))
            let x0 = (size - w) / 2
            let src = t < 0.5 ? o : n
            clear(d)
            for y in 0..<size { squashRow(d, src, row: y, sx: 0, sw: size, dx: x0, w: w) }
            emit()
        }
    }

    private static func tileFlip(_ o: Src, _ n: Src, _ d: Dst, _ emit: () -> Void) {
        let tiles = 6, ts = 40, frames = 30
        for f in 1...frames {
            let t = Float(f) / Float(frames)
            clear(d)
            for ty in 0..<tiles {
                for tx in 0..<tiles {
                    let lt = clamp01((t - Float(tx + ty) / Float(2 * tiles - 2) * 0.55) / 0.45)
                    let w = max(1, Int(Float(ts) * abs(cos(Float.pi * lt))))
                    let src = lt < 0.5 ? o : n
                    let dx = tx * ts + (ts - w) / 2
                    for y in (ty * ts)..<((ty + 1) * ts) { squashRow(d, src, row: y, sx: tx * ts, sw: ts, dx: dx, w: w) }
                }
            }
            emit()
        }
    }

    private static func blockDrop(_ o: Src, _ n: Src, _ d: Dst, _ emit: () -> Void) {
        let blocks = 6, bs = 40, frames = 36
        for f in 1...frames {
            let t = Float(f) / Float(frames)
            copy(o, d)
            for row in stride(from: blocks - 1, through: 0, by: -1) {
                for bx in 0..<blocks {
                    let order = (blocks - 1 - row) * blocks + (cellHash(bx, row) % blocks)
                    let lt = clamp01((t - Float(order) / Float(blocks * blocks) * 0.75) / 0.25)
                    if lt <= 0 { continue }
                    let target = row * bs
                    let y = min(target, Int(Float(-bs) + Float(target + bs) * lt * lt))
                    for r in 0..<bs {
                        let dy = y + r
                        if dy < 0 || dy >= size { continue }
                        for x in 0..<bs { d[dy * size + bx * bs + x] = n[(target + r) * size + bx * bs + x] }
                    }
                }
            }
            emit()
        }
    }

    private static func melt(_ o: Src, _ n: Src, _ d: Dst, _ emit: () -> Void) {
        let col = 4, frames = 30
        for f in 1...frames {
            let t = Float(f) / Float(frames)
            copy(n, d)
            for x in stride(from: 0, to: size, by: col) {
                let start = Float(cellHash(x, 7)) / 255 * 0.3
                let lt = clamp01((t - start) / 0.7)
                let dy = Int(lt * lt * 240)
                if dy >= size { continue }
                for y in dy..<size {
                    for c in 0..<col { d[y * size + x + c] = o[(y - dy) * size + x + c] }
                }
            }
            emit()
        }
    }

    private static func zoomPunch(_ o: Src, _ n: Src, _ d: Dst, _ emit: () -> Void) {
        let frames = 26
        var srcX = [Int](repeating: 0, count: size)
        for f in 1...frames {
            let u = Float(f) / Float(frames) - 1
            let cubic: Float = 2.70158 * u * u * u
            let e: Float = 1 + cubic + 1.70158 * u * u  // easeOutBack
            let s = max(2, Int(e * 240))
            let x0 = (size - s) / 2, y0 = (size - s) / 2
            copy(o, d)
            let xa = max(0, x0), xb = min(size, x0 + s)
            if xa < xb { for x in xa..<xb { srcX[x] = ((x - x0) * size) / s } }
            let ya = max(0, y0), yb = min(size, y0 + s)
            if xa < xb && ya < yb {
                for y in ya..<yb {
                    let srow = (((y - y0) * size) / s) * size
                    for x in xa..<xb { d[y * size + x] = n[srow + srcX[x]] }
                }
            }
            emit()
        }
    }

    /// `blitScaled`: nearest-neighbour scale of a whole cover into (dx, dy, dw, dh).
    private static func blitScaled(_ s: Src, _ d: Dst, _ dx: Float, _ dy: Float, _ dw: Float, _ dh: Float) {
        if dw < 1 || dh < 1 { return }
        let x0 = max(0, Int(ceil(dx))), x1 = min(size, Int(ceil(dx + dw)))
        let y0 = max(0, Int(ceil(dy))), y1 = min(size, Int(ceil(dy + dh)))
        if x0 >= x1 || y0 >= y1 { return }
        var sx = [Int](repeating: 0, count: size)
        for x in x0..<x1 { sx[x] = clampPx(Int((Float(x) - dx) * 240 / dw)) }
        for y in y0..<y1 {
            let srow = clampPx(Int((Float(y) - dy) * 240 / dh)) * size
            for x in x0..<x1 { d[y * size + x] = s[srow + sx[x]] }
        }
    }

    private static func cornerPeel(_ o: Src, _ n: Src, _ d: Dst, _ emit: () -> Void) {
        let frames = 28
        for f in 1...frames {
            let fq = Int((359.4 * (1 - easeInOut(Float(f) / Float(frames))) - 10) * 1.41421)
            for y in 0..<size {
                for x in 0..<size {
                    let q = x + y, i = y * size + x
                    if q > fq {
                        var c = n[i]
                        if q < fq + 22 { c = shade(c, 0.5 + 0.5 * Float(q - fq) / 22) }
                        d[i] = c
                    } else {
                        let k = fq - q, sx = x + k, sy = y + k
                        if sx < size && sy < size {
                            var c = blend(o[sy * size + sx], white, 18)
                            if k < 8 { c = shade(c, 0.75 + Float(k) / 32) }
                            d[i] = c
                        } else {
                            d[i] = o[i]
                        }
                    }
                }
            }
            emit()
        }
    }

    private struct Shard {
        var ax: Float, ay: Float, bx: Float, by: Float, cx2: Float, cy2: Float
        var cx: Float, cy: Float, delay: Float, dx: Float, rot: Float, area: Float
    }

    private static let shards: [Shard] = {
        var vx = [[Float]](repeating: [Float](repeating: 0, count: 7), count: 7)
        var vy = vx
        for j in 0...6 {
            for i in 0...6 {
                let edge = i == 0 || j == 0 || i == 6 || j == 6
                vx[j][i] = Float(i * 40) + (edge ? 0 : (Float(cellHash(j * 31 + i, 1)) / 255 - 0.5) * 22)
                vy[j][i] = Float(j * 40) + (edge ? 0 : (Float(cellHash(j * 17 + i, 2)) / 255 - 0.5) * 22)
            }
        }
        var result: [Shard] = []
        var k = 0
        for j in 0..<6 {
            for i in 0..<6 {
                for h in 0..<2 {
                    let ax = vx[j][i], ay = vy[j][i]
                    let bx = h == 0 ? vx[j][i + 1] : vx[j + 1][i + 1]
                    let by = h == 0 ? vy[j][i + 1] : vy[j + 1][i + 1]
                    let cx2 = h == 0 ? vx[j + 1][i + 1] : vx[j + 1][i]
                    let cy2 = h == 0 ? vy[j + 1][i + 1] : vy[j + 1][i]
                    let cx = (ax + bx + cx2) / 3, cy = (ay + by + cy2) / 3
                    let delay = hypot(cx - 120, cy - 120) / 170 * 0.4 + Float(cellHash(k, 77)) / 255 * 0.12
                    let dx = (Float(cellHash(k, 3)) / 255 - 0.5) * 90
                    let rot = (Float(cellHash(k, 9)) / 255 - 0.5) * 3
                    let area = (bx - ax) * (cy2 - ay) - (by - ay) * (cx2 - ax)
                    result.append(Shard(ax: ax, ay: ay, bx: bx, by: by, cx2: cx2, cy2: cy2,
                                        cx: cx, cy: cy, delay: delay, dx: dx, rot: rot, area: area))
                    k += 1
                }
            }
        }
        return result
    }()

    private static func shatter(_ o: Src, _ n: Src, _ d: Dst, _ emit: () -> Void) {
        let frames = 32
        for f in 1...frames {
            let t = Float(f) / Float(frames)
            copy(n, d)
            for s in shards {
                let lt = clamp01((t - s.delay) / 0.5)
                let ox = s.dx * lt, oy = lt * lt * 330, th = s.rot * lt
                let cs = cos(th), sn = sin(th)
                let cracks = t > s.delay - 0.18
                var minX: Float = 1e9, maxX: Float = -1e9, minY: Float = 1e9, maxY: Float = -1e9
                for (px, py) in [(s.ax, s.ay), (s.bx, s.by), (s.cx2, s.cy2)] {
                    let rx = s.cx + cs * (px - s.cx) - sn * (py - s.cy) + ox
                    let ry = s.cy + sn * (px - s.cx) + cs * (py - s.cy) + oy
                    minX = min(minX, rx); maxX = max(maxX, rx); minY = min(minY, ry); maxY = max(maxY, ry)
                }
                let x0 = max(0, Int(minX)), x1 = min(size - 1, Int(maxX) + 1)
                let y0 = max(0, Int(minY)), y1 = min(size - 1, Int(maxY) + 1)
                if x0 > x1 || y0 > y1 { continue }
                for y in y0...y1 {
                    for x in x0...x1 {
                        let rx = Float(x) + 0.5 - s.cx - ox, ry = Float(y) + 0.5 - s.cy - oy
                        let sx = s.cx + cs * rx + sn * ry, sy = s.cy - sn * rx + cs * ry
                        let w0 = ((s.bx - s.ax) * (sy - s.ay) - (s.by - s.ay) * (sx - s.ax)) / s.area
                        let w1 = ((s.cx2 - s.bx) * (sy - s.by) - (s.cy2 - s.by) * (sx - s.bx)) / s.area
                        let w2 = 1 - w0 - w1
                        if w0 < 0 || w1 < 0 || w2 < 0 { continue }
                        var c = o[clampPx(Int(sy)) * size + clampPx(Int(sx))]
                        if cracks && min(w0, min(w1, w2)) < 0.035 { c = blend(c, white, lt > 0 ? 14 : 24) }
                        d[y * size + x] = c
                    }
                }
            }
            emit()
        }
    }

    private static func cubeTurn(_ o: Src, _ n: Src, _ d: Dst, _ emit: () -> Void) {
        let frames = 26
        for f in 1...frames {
            let th = easeInOut(Float(f) / Float(frames)) * (.pi / 2), sn = sin(th), cs = cos(th)
            let wa = 240 * cs
            clear(d)
            for x in 0..<size {
                let src: Src, u: Float, h: Float, sh: Float
                if Float(x) < wa {
                    src = o; u = Float(x) / wa; h = 1 - 0.18 * sn * (1 - u); sh = 1 - 0.55 * sn
                } else {
                    src = n; u = (Float(x) - wa) / max(1, 240 - wa); h = 1 - 0.18 * cs * u; sh = 1 - 0.55 * cs
                }
                let sx = clampPx(Int(u * 240))
                for y in 0..<size {
                    let sy = (Float(y) - 120) / h + 120
                    if sy < 0 || sy >= 240 { continue }
                    d[y * size + x] = shade(src[Int(sy) * size + sx], sh)
                }
            }
            emit()
        }
    }

    private static func jellyDrop(_ o: Src, _ n: Src, _ d: Dst, _ emit: () -> Void) {
        let frames = 34
        for f in 1...frames {
            let t = Float(f) / Float(frames)
            copy(o, d)
            if t < 0.4 {
                let a = t / 0.4
                blitScaled(n, d, 0, -240 * (1 - a * a), 240, 240)
            } else {
                let u = (t - 0.4) / 0.6
                let s = 1 - 0.28 * exp(-4 * u) * cos(u * 20), w = 240 / s
                blitScaled(n, d, (240 - w) / 2, 240 - 240 * s, w, 240 * s)
            }
            emit()
        }
    }

    private static let tileSpinOrder: [Int] = {
        let key: [Float] = (0..<36).map { (i: Int) -> Float in
            let x = Float(i % 6) - 2.5, y = Float(i / 6) - 2.5
            return max(abs(x), abs(y)) + atan2(y, x) / (2 * .pi)
        }
        // Stable insertion order, as the firmware sorts.
        var order = Array(0..<36)
        for i in 1..<36 {
            var j = i
            while j > 0 && key[order[j]] < key[order[j - 1]] { order.swapAt(j, j - 1); j -= 1 }
        }
        return order
    }()

    private static func tileSpin(_ o: Src, _ n: Src, _ d: Dst, _ emit: () -> Void) {
        let frames = 32
        for f in 1...frames {
            let t = Float(f) / Float(frames)
            clear(d)
            for (r, tile) in tileSpinOrder.enumerated() {
                let tx = tile % 6, ty = tile / 6
                let lt = clamp01((t - Float(r) / 36 * 0.6) / 0.4), e = easeInOut(lt)
                let firstHalf = lt < 0.5
                let a = firstHalf ? e * .pi : (e - 1) * .pi, sc = 1 - 0.4 * sin(.pi * lt)
                let src = firstHalf ? o : n
                let ccx = Float(tx * 40 + 20), ccy = Float(ty * 40 + 20), cs = cos(a), sn = sin(a)
                let ext = 20 * sc * 1.4143
                let x0 = max(0, Int(ccx - ext)), x1 = min(size - 1, Int(ccx + ext))
                let y0 = max(0, Int(ccy - ext)), y1 = min(size - 1, Int(ccy + ext))
                if x0 > x1 || y0 > y1 { continue }
                for y in y0...y1 {
                    for x in x0...x1 {
                        let dx = Float(x) + 0.5 - ccx, dy = Float(y) + 0.5 - ccy
                        let lx = (cs * dx + sn * dy) / sc, ly = (-sn * dx + cs * dy) / sc
                        if lx < -20 || lx >= 20 || ly < -20 || ly >= 20 { continue }
                        d[y * size + x] = src[Int(ccy + ly) * size + Int(ccx + lx)]
                    }
                }
            }
            emit()
        }
    }

    private static func infiniteZoom(_ o: Src, _ n: Src, _ d: Dst, _ emit: () -> Void) {
        let frames = 30
        for f in 1...frames {
            let z = easeInOut(Float(f) / Float(frames)), k = pow(6, z), sa = 240 * k, sb = 40 * k
            blitScaled(o, d, 120 - sa / 2, 120 - sa / 2, sa, sa)
            if z < 0.97 {
                let f0 = max(0, Int(120 - sb / 2 - 2)), f1 = min(size, Int(120 + sb / 2 + 2))
                if f0 < f1 { for y in f0..<f1 { for x in f0..<f1 { d[y * size + x] = white } } }
            }
            blitScaled(n, d, 120 - sb / 2, 120 - sb / 2, sb, sb)
            emit()
        }
    }

    private static func rgbSplit(_ o: Src, _ n: Src, _ d: Dst, _ emit: () -> Void) {
        let frames = 22
        for f in 1...frames {
            let t = Float(f) / Float(frames)
            let off = Int(sin(.pi * t) * 22)
            let src = t < 0.5 ? o : n
            for y in 0..<size {
                let row = y * size, grow = clampPx(y + off / 2) * size
                for x in 0..<size {
                    let red = src[row + clampPx(x - off)] & 0x0000_00FF
                    let green = src[grow + x] & 0x0000_FF00
                    let blue = src[row + clampPx(x + off)] & 0x00FF_0000
                    d[row + x] = 0xFF00_0000 | red | green | blue
                }
            }
            emit()
        }
    }

    private static func accordion(_ o: Src, _ n: Src, _ d: Dst, _ emit: () -> Void) {
        let frames = 24, pleats = 8, pw = 30
        for f in 1...frames {
            let e = easeInOut(Float(f) / Float(frames)), w = Float(pw) * (1 - e)
            copy(n, d)
            if w >= 0.5 {
                for i in 0..<pleats {
                    let dx0 = Int((240 - Float(pleats - i) * w).rounded())
                    let dx1 = Int((240 - Float(pleats - i - 1) * w).rounded())
                    let dw = dx1 - dx0
                    if dw <= 0 { continue }
                    let sh = 1 - (i & 1 != 0 ? 0.45 : 0.08) * e
                    for y in 0..<size {
                        for x in 0..<dw { d[y * size + dx0 + x] = shade(o[y * size + i * pw + (x * pw) / dw], sh) }
                    }
                }
            }
            emit()
        }
    }

    private static let inkMask: [UInt8] = {
        var sx = [Float](repeating: 0, count: 6), sy = sx, sr = sx
        for i in 0..<6 {
            sx[i] = 30 + Float(cellHash(i * 11 + 1, 4)) / 255 * 180
            sy[i] = 30 + Float(cellHash(i * 13 + 2, 5)) / 255 * 180
            sr[i] = 0.7 + Float(cellHash(i * 5 + 9, 6)) / 255 * 0.6
        }
        var values = [Float](repeating: 0, count: 57_600)
        var mx: Float = 1
        for y in 0..<240 {
            for x in 0..<240 {
                var dist: Float = 1e9
                for i in 0..<6 { dist = min(dist, hypot(Float(x) - sx[i], Float(y) - sy[i]) / sr[i]) }
                let fx = Float(x), fy = Float(y)
                let w1: Float = sin(fx * 0.11 + fy * 0.07)
                let w2: Float = sin(fx * 0.23 - fy * 0.19)
                let w3: Float = sin((fx + fy) * 0.31)
                let grain: Float = Float(cellHash(x, y)) / 255 * 6
                dist += (w1 + w2 + w3) * 7 + grain
                values[y * 240 + x] = dist
                mx = max(mx, dist)
            }
        }
        return values.map { UInt8(max(0, $0) / mx * 250) }
    }()

    private static func inkBleed(_ o: Src, _ n: Src, _ d: Dst, _ emit: () -> Void) {
        let frames = 28
        for f in 1...frames {
            let lv = Int(easeInOut(Float(f) / Float(frames)) * 262)
            for i in 0..<count {
                let v = Int(inkMask[i])
                d[i] = v < lv ? (v > lv - 7 ? opaqueBlack : n[i]) : o[i]
            }
            emit()
        }
    }

    private static func crackSplit(_ o: Src, _ n: Src, _ d: Dst, _ emit: () -> Void) {
        // The board draws a new random crack every time; the app draws its own.
        var crack = [Int](repeating: 120, count: size)
        var cx = 120
        for y in 0..<size {
            cx += Int.random(in: -4...4)
            cx = max(70, min(170, cx))
            crack[y] = cx
        }
        for f in 1...10 {
            let ly = (f * size) / 10
            copy(o, d)
            for y in 0..<ly { for x in (crack[y] - 1)...(crack[y] + 1) { d[y * size + x] = white } }
            emit()
        }
        let splitFrames = 22
        for f in 1...splitFrames {
            let off = Int(easeInOut(Float(f) / Float(splitFrames)) * 135)
            for y in 0..<size {
                for x in 0..<size {
                    let l = x + off, r = x - off
                    if l < crack[y] {
                        d[y * size + x] = o[y * size + l]
                    } else if r >= crack[y] && r < size {
                        d[y * size + x] = o[y * size + r]
                    } else {
                        d[y * size + x] = n[y * size + x]
                    }
                }
            }
            emit()
        }
    }

    private static func sandPile(_ o: Src, _ n: Src, _ d: Dst, _ emit: () -> Void) {
        let frames = 36
        for f in 1...frames {
            let t = Float(f) / Float(frames)
            copy(o, d)
            for y in stride(from: size - 1, through: 0, by: -1) {
                let rowLand = Float(size - 1 - y) / 240 * 0.72 + 0.06
                for x in 0..<size {
                    let tl = rowLand + Float(cellHash(x, y)) / 255 * 0.08, ts = tl - 0.2
                    if t < ts { continue }
                    let i = y * size + x
                    if t >= tl { d[i] = n[i]; continue }
                    let u = (t - ts) / 0.2
                    let py = Int(-8 + Float(y + 8) * u * u)
                    if py >= 0 { d[py * size + x] = n[i] }
                }
            }
            emit()
        }
    }

    private static func halftone(_ o: Src, _ n: Src, _ d: Dst, _ emit: () -> Void) {
        var lumOld = [Float](repeating: 0, count: 900), lumNew = lumOld
        for c in 0..<900 {
            let cx = (c % 30) * 8, cy = (c / 30) * 8
            var so: Float = 0, sn: Float = 0
            for y in 0..<8 {
                for x in 0..<8 {
                    so += luma(o[(cy + y) * size + cx + x])
                    sn += luma(n[(cy + y) * size + cx + x])
                }
            }
            lumOld[c] = so / 64; lumNew[c] = sn / 64
        }
        let frames = 28
        for f in 1...frames {
            let t = Float(f) / Float(frames)
            let firstHalf = t < 0.5
            let k = firstHalf ? t * 2 : (1 - t) * 2
            let src = firstHalf ? o : n
            let lum = firstHalf ? lumOld : lumNew
            for y in 0..<size {
                for x in 0..<size {
                    let c = (y >> 3) * 30 + (x >> 3)
                    let dx = Float(x & 7) - 3.5, dy = Float(y & 7) - 3.5
                    let radius = (1 - k) * 7.5 * (0.35 + 0.65 * lum[c])
                    d[y * size + x] = dx * dx + dy * dy < radius * radius ? src[y * size + x] : opaqueBlack
                }
            }
            emit()
        }
    }
}
