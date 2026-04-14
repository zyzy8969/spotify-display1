import UIKit
import CoreImage
import CoreGraphics

/// sRGB-oriented resize + grade, then Atkinson-dither to little-endian RGB565 for ESP32 (115 200 bytes).
/// Pipeline: JPEG decode → CIImage (Lanczos resize + color grade, single GPU render) → RGBA rasterize → dither+pack.
enum ImageProcessor {
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
    static func convertToRGB565(imageData: Data) throws -> Data {
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

        // Color grade (GPU).
        ci = applyGrading(ci)

        // Single GPU render → CGImage.
        let bounds = CGRect(origin: .zero, size: targetSize)
        guard let output = ciContext.createCGImage(ci, from: bounds) else {
            throw SpotifyDisplayError.conversionFailed
        }

        return try packRGB565LittleEndian(cgImage: output)
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
    private static func packRGB565LittleEndian(cgImage: CGImage) throws -> Data {
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

                                let oldR = min(255.0, max(0.0, b[i3]))
                                let oldG = min(255.0, max(0.0, b[i3 + 1]))
                                let oldB = min(255.0, max(0.0, b[i3 + 2]))

                                let r5 = Int(UInt16(oldR) >> 3)
                                let g6 = Int(UInt16(oldG) >> 2)
                                let b5 = Int(UInt16(oldB) >> 3)
                                let packed = UInt16((r5 << 11) | (g6 << 5) | b5)

                                let base = i * 2
                                o[base]     = UInt8(truncatingIfNeeded: packed & 0xff)
                                o[base + 1] = UInt8(truncatingIfNeeded: packed >> 8)

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
