import UIKit
import CoreImage
import CoreGraphics
import Compression

/// How the 24-bit cover is reduced to the panel's RGB565. Picked in Settings (stored under
/// `ditherMode`) so the looks can be compared on the real panel.
enum DitherMode: String, CaseIterable, Identifiable {
    /// Error diffusion: finest detail, but its noise compresses poorly (BLE_PROTOCOL 1.11 deflate).
    case atkinson
    /// Ordered 8x8 Bayer: a fixed pattern. No banding, and compresses much better than Atkinson.
    case bayer
    /// Plain rounding: smallest transfers, visible banding in smooth gradients.
    case off = "none"

    static let storageKey = "ditherMode"
    static let fallback = DitherMode.atkinson
    var id: String { rawValue }

    static var current: DitherMode {
        DitherMode(rawValue: UserDefaults.standard.string(forKey: storageKey) ?? "") ?? fallback
    }

    var displayName: String {
        switch self {
        case .atkinson: return "Atkinson"
        case .bayer: return "Pattern (Bayer)"
        case .off: return "None"
        }
    }

    var blurb: String {
        switch self {
        case .atkinson: return "finest detail, biggest transfer"
        case .bayer: return "smooth, smaller transfer"
        case .off: return "smallest transfer, may band"
        }
    }

    /// Appended to the SD cache key so each look gets its own cached covers. "|c=native" marks
    /// ungraded colour (2026-11-22): covers cached before that were colour-boosted and must not be
    /// reused. Atkinson adds nothing more; the other modes add their name.
    var cacheKeySuffix: String {
        let colour = ImageProcessor.applyColorGrade ? "" : "|c=native"
        return colour + (self == .atkinson ? "" : "|d=\(rawValue)")
    }
}

/// sRGB-oriented resize (+ optional grade), then dither to little-endian RGB565 for ESP32 (115 200 bytes).
/// Pipeline: JPEG decode → CIImage (Lanczos resize, single GPU render) → RGBA rasterize → dither+pack.
enum ImageProcessor {
    /// Owner's choice 2026-11-22: show covers in their native colours. The old TFT boost
    /// (`applyGrading`: lifted blacks, gamma 0.85, vibrance, saturation 1.3, contrast 1.22) is
    /// kept below but off. Setting this to true also brings back the old cache keys.
    static let applyColorGrade = false

    /// Raw DEFLATE (RFC 1951, no zlib header): what Apple's `COMPRESSION_ZLIB` emits and what the
    /// board's ROM `tinfl_decompress` reads (BLE_PROTOCOL 1.11). Nil when it would not be smaller.
    static func deflateRaw(_ data: Data) -> Data? {
        guard !data.isEmpty else { return nil }
        let capacity = data.count  // bigger than the input = not worth sending
        var out = Data(count: capacity)
        let written = out.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) -> Int in
            data.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Int in
                guard let d = dst.bindMemory(to: UInt8.self).baseAddress,
                      let s = src.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_encode_buffer(d, capacity, s, data.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written > 0, written < data.count else { return nil }
        out.count = written
        return out
    }

    private static let targetW = 240
    private static let targetH = 240
    private static let targetSize = CGSize(width: targetW, height: targetH)

    /// Shared CIContext — reused across calls; GPU-backed when available.
    private static let ciContext: CIContext = {
        if let space = CGColorSpace(name: CGColorSpace.sRGB) {
            return CIContext(options: [
                .workingColorSpace: space,
                .outputColorSpace: space
            ])
        }
        return CIContext()
    }()

    // MARK: - Public

    /// Decodes image data, resizes, grades, dithers, and returns 115 200 bytes of LE RGB565.
    /// Safe to call from any thread (no UIKit dependency on main).
    static func convertToRGB565(imageData: Data, dither: DitherMode = .current) throws -> Data {
        guard let uiImage = UIImage(data: imageData),
              let srcCG = uiImage.cgImage else {
            throw SpotifyDisplayError.conversionFailed
        }

        // Build a single CIImage pipeline: scale → crop → grade.
        var ci = CIImage(cgImage: srcCG)
        let srcW = CGFloat(srcCG.width)
        let srcH = CGFloat(srcCG.height)
        let scale = max(CGFloat(targetW) / srcW, CGFloat(targetH) / srcH)

        // Lanczos resize (GPU).
        if let lanczos = CIFilter(name: "CILanczosScaleTransform") {
            lanczos.setValue(ci, forKey: kCIInputImageKey)
            lanczos.setValue(Float(scale), forKey: kCIInputScaleKey)
            lanczos.setValue(1.0, forKey: kCIInputAspectRatioKey)
            if let out = lanczos.outputImage { ci = out }
        }

        // Center-crop to exact target.
        let scaledW = srcW * scale
        let scaledH = srcH * scale
        let cropX = (scaledW - CGFloat(targetW)) / 2
        let cropY = (scaledH - CGFloat(targetH)) / 2
        ci = ci.cropped(to: CGRect(x: cropX, y: cropY, width: CGFloat(targetW), height: CGFloat(targetH)))
            .transformed(by: CGAffineTransform(translationX: -cropX, y: -cropY))

        // Color grade (GPU) — off: native colours (see `applyColorGrade`).
        if applyColorGrade { ci = applyGrading(ci) }

        // Single GPU render → CGImage.
        let bounds = CGRect(origin: .zero, size: targetSize)
        guard let output = ciContext.createCGImage(ci, from: bounds) else {
            throw SpotifyDisplayError.conversionFailed
        }

        return try packRGB565LittleEndian(cgImage: output, dither: dither)
    }

    // MARK: - Grading

    /// Tuned for 240px TFT (ST7789): punchy saturation, lifted shadows, extra vibrance.
    private static func applyGrading(_ input: CIImage) -> CIImage {
        var img = input

        // Lift blacks / clip whites — TFT panels have poor black levels, so crushed shadows look muddy.
        if let clamp = CIFilter(name: "CIColorClamp") {
            clamp.setValue(img, forKey: kCIInputImageKey)
            clamp.setValue(CIVector(x: 0.03, y: 0.03, z: 0.03, w: 0.0), forKey: "inputMinComponents")
            clamp.setValue(CIVector(x: 0.96, y: 0.96, z: 0.96, w: 1.0), forKey: "inputMaxComponents")
            if let out = clamp.outputImage { img = out }
        }

        // Slight gamma push — brightens midtones for a small backlit display.
        if let gamma = CIFilter(name: "CIGammaAdjust") {
            gamma.setValue(img, forKey: kCIInputImageKey)
            gamma.setValue(0.85, forKey: "inputPower")
            if let out = gamma.outputImage { img = out }
        }

        // Vibrance boosts muted colours without over-saturating already vivid areas.
        if let vibrance = CIFilter(name: "CIVibrance") {
            vibrance.setValue(img, forKey: kCIInputImageKey)
            vibrance.setValue(0.25, forKey: "inputAmount")
            if let out = vibrance.outputImage { img = out }
        }

        // Main saturation + contrast push.
        if let color = CIFilter(name: "CIColorControls") {
            color.setValue(img, forKey: kCIInputImageKey)
            color.setValue(1.30, forKey: kCIInputSaturationKey)
            color.setValue(0.01, forKey: kCIInputBrightnessKey)
            color.setValue(1.22, forKey: kCIInputContrastKey)
            if let out = color.outputImage { img = out }
        }

        return img
    }

    // MARK: - RGB565 packing with Atkinson dithering

    /// Rasterizes the graded CGImage to RGBA, then Atkinson-dithers to LE RGB565.
    /// Uses an interleaved RGB float buffer + unsafe pointers — eliminates ~1 M function calls vs the old per-channel approach.
    /// 8x8 Bayer threshold matrix (0...63).
    private static let bayer8: [Float] = [
         0, 32,  8, 40,  2, 34, 10, 42,
        48, 16, 56, 24, 50, 18, 58, 26,
        12, 44,  4, 36, 14, 46,  6, 38,
        60, 28, 52, 20, 62, 30, 54, 22,
         3, 35, 11, 43,  1, 33,  9, 41,
        51, 19, 59, 27, 49, 17, 57, 25,
        15, 47,  7, 39, 13, 45,  5, 37,
        63, 31, 55, 23, 61, 29, 53, 21,
    ]

    private static func packRGB565LittleEndian(cgImage: CGImage, dither: DitherMode) throws -> Data {
        let width = targetW
        let height = targetH
        let pixelCount = width * height
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel

        // Rasterize to RGBA.
        var raw = [UInt8](repeating: 0, count: height * bytesPerRow)
        guard let cs = CGColorSpace(name: CGColorSpace.sRGB) else {
            throw SpotifyDisplayError.conversionFailed
        }
        var rasterizeFailed = false
        raw.withUnsafeMutableBytes { ptr in
            guard let base = ptr.baseAddress else { rasterizeFailed = true; return }
            guard let ctx = CGContext(
                data: base, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                space: cs,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { rasterizeFailed = true; return }
            ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        if rasterizeFailed { throw SpotifyDisplayError.conversionFailed }

        // Interleaved RGB float buffer (better cache locality than 3 separate arrays).
        var buf = [Float](repeating: 0, count: pixelCount * 3)
        for i in 0..<pixelCount {
            let o = i * 4
            buf[i * 3]     = Float(raw[o])
            buf[i * 3 + 1] = Float(raw[o + 1])
            buf[i * 3 + 2] = Float(raw[o + 2])
        }

        // Quantisation look-up tables (avoid repeated integer division).
        var dequantR = [Float](repeating: 0, count: 32)
        for v in 0..<32 { dequantR[v] = Float(v * 255) / 31.0 }
        var dequantG = [Float](repeating: 0, count: 64)
        for v in 0..<64 { dequantG[v] = Float(v * 255) / 63.0 }

        // Atkinson quantises by truncation (the diffused error makes up for it). The other modes add
        // an offset first: Bayer a per-pixel threshold in [0, step), None half a step (= rounding).
        // Steps: 8 for 5-bit red/blue, 4 for 6-bit green.
        let diffuse = dither == .atkinson
        var offset5 = [Float](repeating: 0, count: 64)
        var offset6 = [Float](repeating: 0, count: 64)
        for k in 0..<64 {
            let t: Float = dither == .bayer ? (bayer8[k] + 0.5) / 64 : 0.5
            offset5[k] = diffuse ? 0 : t * 8
            offset6[k] = diffuse ? 0 : t * 4
        }

        var le = Data(count: pixelCount * 2)
        le.withUnsafeMutableBytes { outRaw in
            buf.withUnsafeMutableBufferPointer { bufPtr in
                dequantR.withUnsafeBufferPointer { drPtr in
                    dequantG.withUnsafeBufferPointer { dgPtr in
                        let b = bufPtr.baseAddress!
                        let o = outRaw.bindMemory(to: UInt8.self).baseAddress!
                        let dr = drPtr.baseAddress!
                        let dg = dgPtr.baseAddress!

                        for y in 0..<height {
                            let rowOff = y * width
                            for x in 0..<width {
                                let i = rowOff + x
                                let i3 = i * 3

                                let k = ((y & 7) << 3) | (x & 7)
                                let oldR = min(255.0, max(0.0, b[i3] + offset5[k]))
                                let oldG = min(255.0, max(0.0, b[i3 + 1] + offset6[k]))
                                let oldB = min(255.0, max(0.0, b[i3 + 2] + offset5[k]))

                                let r5 = Int(UInt16(oldR) >> 3)
                                let g6 = Int(UInt16(oldG) >> 2)
                                let b5 = Int(UInt16(oldB) >> 3)
                                let packed = UInt16((r5 << 11) | (g6 << 5) | b5)

                                let base = i * 2
                                o[base]     = UInt8(truncatingIfNeeded: packed & 0xff)
                                o[base + 1] = UInt8(truncatingIfNeeded: packed >> 8)

                                if !diffuse { continue }

                                // Atkinson error shares (÷8).
                                let eR = (oldR - dr[r5]) * 0.125
                                let eG = (oldG - dg[g6]) * 0.125
                                let eB = (oldB - dr[b5]) * 0.125 // dequantR reused for 5-bit blue

                                if eR == 0 && eG == 0 && eB == 0 { continue }

                                // Distribute to 6 Atkinson neighbours — inlined, no function calls.
                                if x + 1 < width {
                                    let j = i3 + 3
                                    b[j] += eR; b[j+1] += eG; b[j+2] += eB
                                }
                                if x + 2 < width {
                                    let j = i3 + 6
                                    b[j] += eR; b[j+1] += eG; b[j+2] += eB
                                }
                                if y + 1 < height {
                                    let nextRow = (rowOff + width) * 3
                                    if x > 0 {
                                        let j = nextRow + (x - 1) * 3
                                        b[j] += eR; b[j+1] += eG; b[j+2] += eB
                                    }
                                    let j2 = nextRow + x * 3
                                    b[j2] += eR; b[j2+1] += eG; b[j2+2] += eB
                                    if x + 1 < width {
                                        let j3 = nextRow + (x + 1) * 3
                                        b[j3] += eR; b[j3+1] += eG; b[j3+2] += eB
                                    }
                                }
                                if y + 2 < height {
                                    let j = (rowOff + width * 2 + x) * 3
                                    b[j] += eR; b[j+1] += eG; b[j+2] += eB
                                }
                            }
                        }
                    }
                }
            }
        }
        return le
    }
}
