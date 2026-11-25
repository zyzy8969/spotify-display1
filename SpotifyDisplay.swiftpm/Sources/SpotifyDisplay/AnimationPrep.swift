import UIKit
import ImageIO
import AVFoundation

/// A GIF or video clip as the keychain plays it (BLE_PROTOCOL 1.25): up to `maxFrames` frames of
/// `side` x `side` RGB565 LE, each with its own delay. The board draws 120 x 120 frames doubled, so a GIF
/// costs a quarter of full-size frames over BLE (owner's choice 2026-11-24: half-res, doubled).
struct KeychainAnimation {
    static let side = 120
    /// What fits the board's 2 MiB frame buffer at 120 px (72 x 28,802 bytes). 6 s of video at 12 fps.
    static let maxFrames = 72
    /// The board's limit for the deflated transfer (ANIM_MAX_RAW).
    static let maxPackedBytes = 2 * 1024 * 1024
    /// The board's own floor (ANIM_MIN_DELAY_MS).
    static let minDelayMs = 30

    /// Each `side * side * 2` bytes.
    let frames: [Data]
    let delaysMs: [UInt16]
    /// First frame, 480 x 480 JPEG, for the app's card.
    let posterJPEG: Data

    var count: Int { frames.count }

    /// What the board inflates into: every delay (u16 LE), then every frame.
    var rawPayload: Data {
        var out = Data(capacity: count * 2 + count * Self.side * Self.side * 2)
        for d in delaysMs {
            withUnsafeBytes(of: d.littleEndian) { out.append(contentsOf: $0) }
        }
        for f in frames { out.append(f) }
        return out
    }

    /// The first frame pixel-doubled to 240 x 240, exactly as the board draws it (the app's mirror of the
    /// board's transition starts from it).
    var firstFrame240: Data {
        let s = Self.side
        let full = 240
        guard let first = frames.first, first.count == s * s * 2 else { return Data() }
        let scale = full / s
        let src = [UInt8](first)
        var out = [UInt8](repeating: 0, count: full * full * 2)
        for y in 0..<full {
            let sy = (y / scale) * s
            for x in 0..<full {
                let si = (sy + x / scale) * 2
                let di = (y * full + x) * 2
                out[di] = src[si]
                out[di + 1] = src[si + 1]
            }
        }
        return Data(out)
    }

    /// The animation exactly as the keychain plays it (its 120 px RGB565 frames), for the app's cover.
    /// `UIImage` animations have one frame length, so each frame is repeated to keep the GIF's own timing.
    /// Call off the main thread.
    func previewImage() -> UIImage? {
        let s = Self.side
        var images: [UIImage] = []
        for f in frames {
            guard let cg = Self.cgImage(rgb565: f, side: s) else { return nil }
            images.append(UIImage(cgImage: cg))
        }
        let plan = Self.repeatPlan(delaysMs: delaysMs.map { Int($0) })
        var sequence: [UIImage] = []
        for (image, n) in zip(images, plan.repeats) {
            sequence.append(contentsOf: repeatElement(image, count: n))
        }
        guard !sequence.isEmpty else { return nil }
        return UIImage.animatedImage(with: sequence, duration: Double(sequence.count * plan.unitMs) / 1000)
    }

    /// One frame length (`unitMs`) and how many times each frame repeats, so frame i lasts about
    /// `delaysMs[i]`. At most ~`maxSlots` slots in all (a longer GIF gets a coarser unit).
    static func repeatPlan(delaysMs: [Int], maxSlots: Int = 240) -> (unitMs: Int, repeats: [Int]) {
        let delays = delaysMs.map { max(minDelayMs, $0) }
        guard let shortest = delays.min() else { return (100, []) }
        let total = delays.reduce(0, +)
        let unit = max(shortest, Int((Double(total) / Double(maxSlots)).rounded(.up)), 1)
        return (unit, delays.map { max(1, Int((Double($0) / Double(unit)).rounded())) })
    }

    private static func cgImage(rgb565 data: Data, side: Int) -> CGImage? {
        guard data.count == side * side * 2 else { return nil }
        let src = [UInt8](data)
        var rgba = [UInt8](repeating: 255, count: side * side * 4)
        for i in 0..<(side * side) {
            let v = Int(src[i * 2]) | Int(src[i * 2 + 1]) << 8
            let r = (v >> 11) & 0x1F, g = (v >> 5) & 0x3F, b = v & 0x1F
            rgba[i * 4] = UInt8((r * 255 + 15) / 31)
            rgba[i * 4 + 1] = UInt8((g * 255 + 31) / 63)
            rgba[i * 4 + 2] = UInt8((b * 255 + 15) / 31)
        }
        guard let cs = CGColorSpace(name: CGColorSpace.sRGB),
              let provider = CGDataProvider(data: Data(rgba) as CFData) else { return nil }
        return CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: side * 4,
                       space: cs, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}

extension KeychainAnimation {
    /// Rebuilds a saved animation from its `rawPayload` (delays, then frames) and poster.
    init?(raw: Data, count: Int, posterJPEG: Data) {
        let frameBytes = Self.side * Self.side * 2
        let bytes = [UInt8](raw)
        guard count > 0, bytes.count == count * 2 + count * frameBytes else { return nil }
        let delays = (0..<count).map { UInt16(bytes[$0 * 2]) | UInt16(bytes[$0 * 2 + 1]) << 8 }
        let frames = (0..<count).map { k -> Data in
            let start = count * 2 + k * frameBytes
            return Data(bytes[start..<(start + frameBytes)])
        }
        self.init(frames: frames, delaysMs: delays, posterJPEG: posterJPEG)
    }
}

/// Turns GIF bytes or a video clip into a `KeychainAnimation`. Call off the main thread.
/// Frames are stretched to the square, nothing cropped off (owner's choice 2026-11-24, same as photos),
/// and packed with a fixed ordered (Bayer) dither: error diffusion would change every frame (the picture
/// shimmers) and stop the frames compressing, which is most of what makes a GIF quick to send.
enum AnimationPrep {
    /// One source frame and how long it stays up.
    struct SourceFrame {
        let image: CGImage
        let ms: Int
    }

    static let videoFPS = 12.0
    /// Longest video clip (owner's choice 2026-11-24). The iOS trimmer caps the clip at this.
    static let videoMaxSeconds = 15.0

    // MARK: GIF

    static func fromGIF(_ data: Data) -> KeychainAnimation? {
        guard let frames = gifFrames(data) else { return nil }
        return build(frames)
    }

    /// Decoded frames, sampled down to `maxFrames`. A dropped frame's time goes to the frame kept before
    /// it, so the GIF keeps its length.
    static func gifFrames(_ data: Data, maxFrames: Int = KeychainAnimation.maxFrames) -> [SourceFrame]? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let src = CGImageSourceCreateWithData(data as CFData, options) else { return nil }
        let n = CGImageSourceGetCount(src)
        guard n > 0 else { return nil }
        let delays = (0..<n).map { gifDelayMs(src, $0) }
        let picks = sampleIndices(count: n, max: maxFrames)
        var frames: [SourceFrame] = []
        for (k, i) in picks.enumerated() {
            let end = k + 1 < picks.count ? picks[k + 1] : n
            let ms = delays[i..<end].reduce(0, +)
            guard let image = CGImageSourceCreateImageAtIndex(src, i, nil) else { continue }
            frames.append(SourceFrame(image: image, ms: ms))
        }
        return frames.isEmpty ? nil : frames
    }

    /// `count` indices spread evenly over `0..<count`, at most `max` of them.
    static func sampleIndices(count: Int, max: Int) -> [Int] {
        guard count > max else { return Array(0..<count) }
        return (0..<max).map { $0 * count / max }
    }

    /// A frame's delay. Browsers show 0-10 ms delays as 100 ms, and so does this.
    private static func gifDelayMs(_ src: CGImageSource, _ i: Int) -> Int {
        let props = CGImageSourceCopyPropertiesAtIndex(src, i, nil) as? [String: Any]
        let gif = props?[kCGImagePropertyGIFDictionary as String] as? [String: Any]
        let seconds = (gif?[kCGImagePropertyGIFUnclampedDelayTime as String] as? Double)
            ?? (gif?[kCGImagePropertyGIFDelayTime as String] as? Double)
            ?? 0.1
        let ms = Int((seconds * 1000).rounded())
        return ms <= 10 ? 100 : ms
    }

    // MARK: Video

    static func videoDuration(url: URL) async -> Double? {
        guard let d = try? await AVURLAsset(url: url).load(.duration) else { return nil }
        let s = CMTimeGetSeconds(d)
        return s.isFinite && s > 0 ? s : nil
    }

    /// The whole (already trimmed) video, at most `videoMaxSeconds`, as evenly spaced frames: up to
    /// `videoFPS`, fewer for a long clip so it fits `maxFrames` (a 15 s clip plays at about 5 fps).
    /// `progress` gets 0...1 as frames are read. Nil when cancelled or unreadable.
    static func fromVideo(url: URL,
                          progress: @escaping @Sendable (Double) -> Void = { _ in }) async -> KeychainAnimation? {
        guard let duration = await videoDuration(url: url) else { return nil }
        let from = 0.0
        let seconds = min(duration, videoMaxSeconds)
        guard seconds > 0 else { return nil }
        let count = max(1, min(KeychainAnimation.maxFrames, Int(seconds * videoFPS)))
        let step = seconds / Double(count)
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 480, height: 480)
        let tolerance = CMTime(seconds: step / 2, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance
        let ms = Int((step * 1000).rounded())
        var frames: [SourceFrame] = []
        for k in 0..<count {
            if Task.isCancelled { return nil }
            let time = CMTime(seconds: from + Double(k) * step, preferredTimescale: 600)
            if let result = try? await generator.image(at: time) {
                frames.append(SourceFrame(image: result.image, ms: ms))
            }
            progress(Double(k + 1) / Double(count))
        }
        if Task.isCancelled { return nil }
        return build(frames)
    }

    // MARK: Building

    static func build(_ frames: [SourceFrame]) -> KeychainAnimation? {
        guard let first = frames.first else { return nil }
        let side = KeychainAnimation.side
        var packed: [Data] = []
        var delays: [UInt16] = []
        for f in frames.prefix(KeychainAnimation.maxFrames) {
            guard let px = rgb565(f.image, side: side) else { return nil }
            packed.append(px)
            delays.append(UInt16(clamping: max(KeychainAnimation.minDelayMs, f.ms)))
        }
        guard let poster = squareImage(first.image, side: 480),
              let jpeg = UIImage(cgImage: poster).jpegData(compressionQuality: 0.9) else { return nil }
        return KeychainAnimation(frames: packed, delaysMs: delays, posterJPEG: jpeg)
    }

    /// `image` stretched to a `side` square, over black (transparent GIF pixels).
    static func squareImage(_ image: CGImage, side: Int) -> CGImage? {
        guard image.width > 0, image.height > 0,
              let cs = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: cs, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        let rect = CGRect(x: 0, y: 0, width: side, height: side)
        ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
        ctx.fill(rect)
        ctx.interpolationQuality = .high
        ctx.draw(image, in: rect)
        return ctx.makeImage()
    }

    /// `image` stretched to a `side` square (over black) as RGB565 little-endian, rounded to the nearest
    /// 565 colour. One draw per frame.
    static func rgb565(_ image: CGImage, side: Int) -> Data? {
        let bytesPerRow = side * 4
        var rgba = [UInt8](repeating: 0, count: side * bytesPerRow)
        guard let cs = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let drawn = rgba.withUnsafeMutableBytes { ptr -> Bool in
            guard let ctx = CGContext(data: ptr.baseAddress, width: side, height: side, bitsPerComponent: 8,
                                      bytesPerRow: bytesPerRow, space: cs,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            let rect = CGRect(x: 0, y: 0, width: side, height: side)
            ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
            ctx.fill(rect)
            ctx.interpolationQuality = .high
            ctx.draw(image, in: rect)
            return true
        }
        guard drawn else { return nil }
        return packRGB565Bayer(rgba, side: side)
    }

    /// RGBA bytes -> RGB565 LE with the 8x8 ordered (Bayer) pattern (owner's choice 2026-11-24): smooths
    /// banding like the covers' dither, but the pattern is fixed to the pixel, so it does not crawl from
    /// frame to frame, and it compresses far better than error diffusion. Same thresholds as
    /// `DitherMode.bayer`. Pure black and white stay pure.
    static func packRGB565Bayer(_ rgba: [UInt8], side: Int) -> Data {
        var out = [UInt8](repeating: 0, count: side * side * 2)
        let bayer = ImageProcessor.bayer8
        for y in 0..<side {
            for x in 0..<side {
                let i = y * side + x
                let t = (bayer[((y & 7) << 3) | (x & 7)] + 0.5) / 64
                let r = Int(min(255, Float(rgba[i * 4]) + t * 8)) >> 3
                let g = Int(min(255, Float(rgba[i * 4 + 1]) + t * 4)) >> 2
                let b = Int(min(255, Float(rgba[i * 4 + 2]) + t * 8)) >> 3
                let v = UInt16((r << 11) | (g << 5) | b)
                out[i * 2] = UInt8(v & 0xFF)
                out[i * 2 + 1] = UInt8(v >> 8)
            }
        }
        return Data(out)
    }

    /// RGBA bytes -> RGB565 LE (low byte first), rounding each channel.
    static func packRGB565(_ rgba: [UInt8], pixels: Int) -> Data {
        var out = [UInt8](repeating: 0, count: pixels * 2)
        for i in 0..<pixels {
            let r = (Int(rgba[i * 4]) * 31 + 127) / 255
            let g = (Int(rgba[i * 4 + 1]) * 63 + 127) / 255
            let b = (Int(rgba[i * 4 + 2]) * 31 + 127) / 255
            let v = UInt16((r << 11) | (g << 5) | b)
            out[i * 2] = UInt8(v & 0xFF)
            out[i * 2 + 1] = UInt8(v >> 8)
        }
        return Data(out)
    }
}
