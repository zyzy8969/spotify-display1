import Foundation
import CoreGraphics
import UIKit
#if canImport(TransitionsCore)
import TransitionsCore
#endif

// The app draws a transition with the board's own code (SpotifyDisplay.swiftpm/Sources/TransitionsCore,
// the same C++ the firmware compiles). `tx_run` draws into an in-memory panel instead of the LCD;
// the panel keeps a virtual clock that models the board's SPI cost and pauses, and snapshots the
// picture at every 1/60 s of that clock. The snapshots become CGImages that a view just flips through.

// MARK: - Result

/// Frames of one transition, ready to show. `times[i]` is when frame i appears, in seconds from the
/// start of the transition (board time, before any rescaling). `times[0] == 0` (the old picture).
struct RenderedTransition {
    let index: Int
    let frames: [CGImage]
    let times: [TimeInterval]
    /// Modelled length of the whole transition on the board, in seconds.
    let duration: TimeInterval

    static func empty(index: Int) -> RenderedTransition {
        RenderedTransition(index: index, frames: [], times: [], duration: 0)
    }

    var isEmpty: Bool { frames.isEmpty }
    var lastFrame: CGImage? { frames.last }

    /// Index of the frame on screen at `t` seconds (board time): the last one whose time has come.
    func frameIndex(at t: TimeInterval) -> Int {
        guard !times.isEmpty else { return 0 }
        if t <= 0 { return 0 }
        if t >= times[times.count - 1] { return times.count - 1 }
        var lo = 0
        var hi = times.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if times[mid] <= t { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    func frame(at t: TimeInterval) -> CGImage? {
        frames.isEmpty ? nil : frames[frameIndex(at: t)]
    }
}

/// How finely a transition is captured.
struct TransitionRenderOptions {
    /// Snapshot rate on the virtual clock.
    var fps: Double = 60
    /// At most this many frames are kept (dropped evenly over time beyond that).
    var maxFrames: Int = 90
    /// Output side in pixels: 240 (full) or 240 divided by a whole number (box-filtered down).
    var outputSide: Int = 240

    static let mirror = TransitionRenderOptions()
    static let preview = TransitionRenderOptions(fps: 30, maxFrames: 30, outputSide: 120)
}

// MARK: - Renderer

/// Runs the shared core off the main thread. All `tx_run` calls go through one serial queue: the
/// core keeps static state (panel pointer, lookup tables, random generator) and is not thread-safe.
final class TransitionRenderer {
    static let shared = TransitionRenderer()

    static let side = 240
    static let pixelCount = 240 * 240
    static let frameBytes = 240 * 240 * 2

    private let queue = DispatchQueue(label: "SpotifyDisplay.TransitionRenderer", qos: .userInitiated)
    /// Scratch frame the frame-composed transitions build into. Only touched on `queue`.
    private let compose: UnsafeMutablePointer<UInt16>

    private init() {
        compose = UnsafeMutablePointer<UInt16>.allocate(capacity: TransitionRenderer.pixelCount)
        compose.initialize(repeating: 0, count: TransitionRenderer.pixelCount)
    }

    /// Renders transition `index` from `old` (nil = black, like the board's empty screen) to `new`.
    /// Frames are LE RGB565, 240x240 (the bytes the app sends). Never throws; a bad frame gives an
    /// empty result.
    func render(index: Int, old: Data?, new: Data, seed: UInt32,
                options: TransitionRenderOptions = .mirror) async -> RenderedTransition {
        await withCheckedContinuation { (cont: CheckedContinuation<RenderedTransition, Never>) in
            queue.async {
                let result = self.renderOnQueue(index: index, old: old, new: new, seed: seed, options: options)
                cont.resume(returning: result)
            }
        }
    }

    /// The name the firmware announces for `index` (`TRANSITION:<name>`).
    static func boardName(_ index: Int) -> String {
        guard let c = tx_name(Int32(index)) else { return "Unknown" }
        return String(cString: c)
    }

    // MARK: Work on the serial queue

    private func renderOnQueue(index: Int, old: Data?, new: Data, seed: UInt32,
                               options: TransitionRenderOptions) -> RenderedTransition {
        let n = Self.pixelCount
        guard new.count >= Self.frameBytes else { return .empty(index: index) }

        // Index 255 (no transition: every one switched off) or anything else outside the board's
        // table: the board shows the new frame at once, so the mirror cuts straight to it.
        if index < 0 || index >= 52 {
            var pixels = [UInt16](repeating: 0, count: n)
            Self.load(new, into: &pixels)
            guard let image = Self.makeImage(pixels, factor: 1) else { return .empty(index: index) }
            return RenderedTransition(index: index, frames: [image], times: [0], duration: 0)
        }

        var oldPixels = [UInt16](repeating: 0, count: n)
        if let old, old.count >= Self.frameBytes {
            Self.load(old, into: &oldPixels)
        }
        var newPixels = [UInt16](repeating: 0, count: n)
        Self.load(new, into: &newPixels)

        let capture = CapturePanel(start: oldPixels, fps: options.fps, maxFrames: max(2, options.maxFrames))
        let ctxPointer = Unmanaged.passUnretained(capture).toOpaque()

        // Closures that capture nothing convert to C function pointers; the Swift object rides in ctx.
        var panel = TxPanel(
            ctx: ctxPointer,
            bitmap: { ctx, x, y, px, w, h in
                guard let ctx, let px else { return }
                Unmanaged<CapturePanel>.fromOpaque(ctx).takeUnretainedValue()
                    .bitmap(x: Int(x), y: Int(y), px: px, w: Int(w), h: Int(h))
            },
            pixel: { ctx, x, y, c in
                guard let ctx else { return }
                Unmanaged<CapturePanel>.fromOpaque(ctx).takeUnretainedValue()
                    .pixel(x: Int(x), y: Int(y), color: c)
            },
            waitUs: { ctx, us in
                guard let ctx else { return }
                Unmanaged<CapturePanel>.fromOpaque(ctx).takeUnretainedValue().wait(us: Double(us))
            },
            allocLarge: nil
        )

        let composePointer = compose
        withExtendedLifetime(capture) {
            oldPixels.withUnsafeBufferPointer { oldBuf in
                newPixels.withUnsafeBufferPointer { newBuf in
                    _ = tx_run(&panel, Int32(index), oldBuf.baseAddress, newBuf.baseAddress, composePointer, seed)
                }
            }
        }
        capture.finish()

        let picked = capture.pickFrames()
        var k = Self.side / max(1, options.outputSide)
        if k < 1 || Self.side % k != 0 { k = 1 }
        var images: [CGImage] = []
        var times: [TimeInterval] = []
        images.reserveCapacity(picked.count)
        times.reserveCapacity(picked.count)
        for snap in picked {
            guard let image = Self.makeImage(snap.pixels, factor: k) else { continue }
            images.append(image)
            times.append(snap.timeUs / 1_000_000)
        }
        if !times.isEmpty { times[0] = 0 }
        return RenderedTransition(index: index, frames: images, times: times,
                                  duration: capture.clockUs / 1_000_000)
    }

    /// LE RGB565 bytes into native UInt16 values (iOS is little-endian, so this is a straight copy).
    private static func load(_ data: Data, into pixels: inout [UInt16]) {
        let bytes = min(data.count, pixels.count * 2)
        pixels.withUnsafeMutableBytes { dst in
            data.withUnsafeBytes { src in
                guard let s = src.baseAddress, let d = dst.baseAddress else { return }
                d.copyMemory(from: s, byteCount: bytes)
            }
        }
    }

    private static let r5to8: [UInt8] = (0..<32).map { UInt8(($0 * 527 + 23) >> 6) }
    private static let g6to8: [UInt8] = (0..<64).map { UInt8(($0 * 259 + 33) >> 6) }

    /// RGB565 frame to an sRGB RGBX8888 CGImage (CGImage has no 565 format), box-filtered by `factor`.
    static func makeImage(_ pixels: [UInt16], factor k: Int) -> CGImage? {
        let w = side / k
        let count = w * w * 4
        var out = [UInt8](repeating: 255, count: count)
        let r8 = r5to8
        let g8 = g6to8
        pixels.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                if k == 1 {
                    for i in 0..<(side * side) {
                        let v = Int(src[i])
                        let o = i * 4
                        dst[o] = r8[v >> 11]
                        dst[o + 1] = g8[(v >> 5) & 0x3F]
                        dst[o + 2] = r8[v & 0x1F]
                    }
                } else {
                    let area = k * k
                    for oy in 0..<w {
                        for ox in 0..<w {
                            var rs = 0, gs = 0, bs = 0
                            for dy in 0..<k {
                                let row = (oy * k + dy) * side + ox * k
                                for dx in 0..<k {
                                    let v = Int(src[row + dx])
                                    rs += Int(r8[v >> 11])
                                    gs += Int(g8[(v >> 5) & 0x3F])
                                    bs += Int(r8[v & 0x1F])
                                }
                            }
                            let o = (oy * w + ox) * 4
                            dst[o] = UInt8(rs / area)
                            dst[o + 1] = UInt8(gs / area)
                            dst[o + 2] = UInt8(bs / area)
                        }
                    }
                }
            }
        }
        let data = out.withUnsafeBufferPointer { Data(buffer: $0) }
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        return CGImage(
            width: w,
            height: w,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: w * 4,
            space: space,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )
    }

    /// Plain-rounding RGBA to LE RGB565 (no dither), for app-made pictures such as the sample covers.
    static func rgb565(from image: CGImage) -> Data? {
        let s = side
        var rgba = [UInt8](repeating: 0, count: s * s * 4)
        let ok: Bool = rgba.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(
                data: buf.baseAddress, width: s, height: s, bitsPerComponent: 8, bytesPerRow: s * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ) else { return false }
            ctx.interpolationQuality = .high
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: s, height: s))
            return true
        }
        guard ok else { return nil }
        var out = Data(count: s * s * 2)
        out.withUnsafeMutableBytes { raw in
            let dst = raw.bindMemory(to: UInt8.self)
            for i in 0..<(s * s) {
                let r = UInt16(rgba[i * 4]) >> 3
                let g = UInt16(rgba[i * 4 + 1]) >> 2
                let b = UInt16(rgba[i * 4 + 2]) >> 3
                let v = (r << 11) | (g << 5) | b
                dst[i * 2] = UInt8(v & 0xFF)
                dst[i * 2 + 1] = UInt8(v >> 8)
            }
        }
        return out
    }
}

// MARK: - Capture panel

/// The in-memory "LCD" `tx_run` draws on. Lives only during one render, on the renderer's queue.
private final class CapturePanel {
    struct Snapshot {
        let timeUs: Double
        let pixels: [UInt16]
    }

    private let width = TransitionRenderer.side
    private let height = TransitionRenderer.side
    private var buffer: [UInt16]
    private(set) var clockUs: Double = 0
    private var intervalUs: Double
    private var nextSnapUs: Double
    private var dirty = false
    private let maxFrames: Int
    private(set) var snapshots: [Snapshot] = []

    // Board cost model: 40 MHz SPI = 0.4 us per RGB565 pixel, plus setup per call.
    private let usPerPixel = 0.4
    private let usPerBitmapCall = 5.0
    private let usPerDrawPixel = 3.0

    init(start: [UInt16], fps: Double, maxFrames: Int) {
        let interval = 1_000_000 / max(1, fps)
        buffer = start
        intervalUs = interval
        nextSnapUs = interval
        self.maxFrames = maxFrames
        snapshots = [Snapshot(timeUs: 0, pixels: start)]
    }

    func bitmap(x: Int, y: Int, px: UnsafePointer<UInt16>, w: Int, h: Int) {
        guard w > 0, h > 0 else { return }
        let x0 = max(0, x)
        let y0 = max(0, y)
        let x1 = min(width, x + w)
        let y1 = min(height, y + h)
        if x1 > x0, y1 > y0 {
            let run = x1 - x0
            buffer.withUnsafeMutableBufferPointer { dst in
                guard let base = dst.baseAddress else { return }
                for row in y0..<y1 {
                    let src = px + ((row - y) * w + (x0 - x))
                    UnsafeMutableRawPointer(base + (row * width + x0))
                        .copyMemory(from: UnsafeRawPointer(src), byteCount: run * 2)
                }
            }
            dirty = true
        }
        advance(Double(w * h) * usPerPixel + usPerBitmapCall)
    }

    func pixel(x: Int, y: Int, color: UInt16) {
        if x >= 0, y >= 0, x < width, y < height {
            buffer[y * width + x] = color
            dirty = true
        }
        advance(usPerDrawPixel)
    }

    func wait(us: Double) {
        advance(us)
    }

    private func advance(_ us: Double) {
        clockUs += us
        guard clockUs >= nextSnapUs else { return }
        if dirty { snapshot() }
        nextSnapUs = ((clockUs / intervalUs).rounded(.down) + 1) * intervalUs
    }

    private func snapshot() {
        snapshots.append(Snapshot(timeUs: clockUs, pixels: buffer))
        dirty = false
        // Bounded memory: past 2x the cap, keep every other frame and halve the rate from here on.
        if snapshots.count >= maxFrames * 2 {
            var kept: [Snapshot] = []
            kept.reserveCapacity(maxFrames)
            for (i, s) in snapshots.enumerated() where i % 2 == 0 { kept.append(s) }
            snapshots = kept
            intervalUs *= 2
        }
    }

    /// The final picture, always.
    func finish() {
        if dirty || snapshots.count == 1 {
            snapshots.append(Snapshot(timeUs: clockUs, pixels: buffer))
            dirty = false
        }
    }

    /// At most `maxFrames`, spread evenly, always keeping the first (old picture) and the last.
    func pickFrames() -> [Snapshot] {
        let count = snapshots.count
        guard count > maxFrames, maxFrames >= 2 else { return snapshots }
        var out: [Snapshot] = []
        out.reserveCapacity(maxFrames)
        var last = -1
        for j in 0..<maxFrames {
            let i = Int((Double(j) * Double(count - 1) / Double(maxFrames - 1)).rounded())
            if i != last {
                out.append(snapshots[i])
                last = i
            }
        }
        return out
    }
}

// MARK: - TRANSITION_START (BLE_PROTOCOL 1.13)

/// `TRANSITION_START:<index>:<seed>:<expectedMs>:<oldBlack>`: the board is about to draw transition
/// `index`. `newFrame` is the RGB565 frame it is drawing, when the app has it (for a cache hit it
/// is filled in a little later, once the downloaded cover is converted).
struct TransitionStartEvent: Identifiable, Equatable {
    let id = UUID()
    let index: Int
    let seed: UInt32
    /// How long this transition took on the board last time (0 = unknown).
    let expectedMs: Int
    /// The board's screen was all black before (nothing shown yet).
    let oldBlack: Bool
    let received: Date
    var newFrame: Data?

    static let prefix = "TRANSITION_START:"

    static func parse(_ text: String, received: Date = Date()) -> TransitionStartEvent? {
        guard text.hasPrefix(prefix) else { return nil }
        let parts = text.dropFirst(prefix.count)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: ":", omittingEmptySubsequences: false)
            .map { String($0) }
        guard parts.count >= 2, let index = Int(parts[0]), let seed = UInt32(parts[1]) else { return nil }
        let expected = parts.count > 2 ? max(0, Int(parts[2]) ?? 0) : 0
        let black = parts.count > 3 ? (parts[3] == "1") : false
        return TransitionStartEvent(index: index, seed: seed, expectedMs: expected, oldBlack: black,
                                    received: received, newFrame: nil)
    }

    static func == (a: TransitionStartEvent, b: TransitionStartEvent) -> Bool {
        a.id == b.id && (a.newFrame == nil) == (b.newFrame == nil)
    }
}

// MARK: - Mirror of the board's transition

/// What the cover view plays while the board draws. Fed by `BLEManager` (start events and frames);
/// read by `ArtStage`. A singleton so the cover view can observe it without new parameters.
@MainActor
final class TransitionMirror: ObservableObject {
    static let shared = TransitionMirror()

    struct Playback: Identifiable {
        let id: UUID
        let index: Int
        /// When the board started drawing (when its announcement arrived).
        let start: Date
        /// The board's own timing of this transition last time, in seconds (0 = unknown).
        let expected: TimeInterval
        var rendered: RenderedTransition?

        /// Board time is stretched so the frames last exactly `expected` when the board told us.
        var timeScale: Double {
            guard let r = rendered, expected > 0, r.duration > 0.001 else { return 1 }
            return expected / r.duration
        }

        /// Wall-clock length of the playback.
        var duration: TimeInterval {
            if let r = rendered, !r.isEmpty { return r.duration * timeScale }
            return expected > 0 ? expected : 1.0
        }

        var end: Date { start.addingTimeInterval(duration) }

        /// Frame for wall-clock `date` (seeks automatically when rendering finished late).
        func frame(at date: Date) -> CGImage? {
            guard let r = rendered, !r.isEmpty else { return nil }
            let t = date.timeIntervalSince(start) / max(0.0001, timeScale)
            return r.frame(at: t)
        }
    }

    @Published private(set) var playback: Playback?
    /// The board sent TRANSITION_START this connection (BLE_PROTOCOL 1.13 firmware).
    @Published private(set) var boardAnnouncesStart = false

    private var pendingOld: Data?
    private var pendingSeed: UInt32 = 0

    private init() {}

    /// The board is starting a transition. `old` = its previous frame (nil = black).
    func begin(_ event: TransitionStartEvent, old: Data?) {
        boardAnnouncesStart = true
        playback = Playback(id: event.id, index: event.index, start: event.received,
                            expected: Double(event.expectedMs) / 1000, rendered: nil)
        pendingOld = old
        pendingSeed = event.seed
        if let frame = event.newFrame {
            provideFrame(frame, for: event.id)
        }
    }

    /// The frame the board is drawing, once known. Renders it with the shared core off the main thread.
    func provideFrame(_ frame: Data, for id: UUID) {
        guard let pb = playback, pb.id == id, pb.rendered == nil else { return }
        let old = pendingOld
        let seed = pendingSeed
        let index = pb.index
        pendingOld = nil
        Task { @MainActor in
            let rendered = await TransitionRenderer.shared.render(index: index, old: old, new: frame, seed: seed)
            guard var current = self.playback, current.id == id else { return }
            current.rendered = rendered
            self.playback = current
            // The frames (~20 MB at full size) are only needed while playing: drop them well after.
            let keepUntil = current.end.addingTimeInterval(10)
            let wait = max(1, keepUntil.timeIntervalSinceNow)
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            if var stale = self.playback, stale.id == id {
                stale.rendered = nil
                self.playback = stale
            }
        }
    }

    /// Disconnected: the board went back to its waiting screen.
    func reset() {
        playback = nil
        pendingOld = nil
        boardAnnouncesStart = false
    }
}
