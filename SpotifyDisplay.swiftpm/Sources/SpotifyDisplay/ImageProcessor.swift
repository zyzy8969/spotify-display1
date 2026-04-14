import UIKit
import CoreImage
import CoreGraphics

/// sRGB-oriented resize + grade, then quantize+dither directly to little-endian RGB565 for ESP32 (115_200 bytes).
enum ImageProcessor {
    private static let targetSize = CGSize(width: 240, height: 240)
    private static let ciContext: CIContext = {
        if let space = CGColorSpace(name: CGColorSpace.sRGB) {
            return CIContext(options: [
                .workingColorSpace: space,
                .outputColorSpace: space
            ])
        }
        return CIContext()
    }()

    static func convertToRGB565(imageData: Data) throws -> Data {
        guard let uiImage = UIImage(data: imageData) else {
            throw SpotifyDisplayError.conversionFailed
        }

        let filled = aspectFillImage(uiImage, to: targetSize)
        guard let cgImage = filled.cgImage else {
            throw SpotifyDisplayError.conversionFailed
        }

        let ciImage = CIImage(cgImage: cgImage)

        let graded = applyGrading(ciImage)

        let bounds = CGRect(origin: .zero, size: targetSize)
        guard let output = ciContext.createCGImage(graded, from: bounds) else {
            throw SpotifyDisplayError.conversionFailed
        }

        return try packRGB565LittleEndian(cgImage: output, width: 240, height: 240)
    }

    /// Aspect-fill into exact 240×240 (album art style).
    private static func aspectFillImage(_ image: UIImage, to size: CGSize) -> UIImage {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { _ in
            UIColor.black.setFill()
            UIBezierPath(rect: CGRect(origin: .zero, size: size)).fill()
            let src = image.size
            let scale = max(size.width / src.width, size.height / src.height)
            let w = src.width * scale
            let h = src.height * scale
            let x = (size.width - w) / 2
            let y = (size.height - h) / 2
            image.draw(in: CGRect(x: x, y: y, width: w, height: h))
        }
    }

    /// Roughly aligned with desktop script: levels + saturation + contrast (Core Image).
    private static func applyGrading(_ input: CIImage) -> CIImage {
        var img = input

        if let clamp = CIFilter(name: "CIColorClamp") {
            clamp.setValue(img, forKey: kCIInputImageKey)
            clamp.setValue(CIVector(x: 0.03, y: 0.03, z: 0.03, w: 0.0), forKey: "inputMinComponents")
            clamp.setValue(CIVector(x: 0.92, y: 0.92, z: 0.92, w: 1.0), forKey: "inputMaxComponents")
            if let out = clamp.outputImage { img = out }
        }

        if let gamma = CIFilter(name: "CIGammaAdjust") {
            gamma.setValue(img, forKey: kCIInputImageKey)
            gamma.setValue(0.92, forKey: "inputPower")
            if let out = gamma.outputImage { img = out }
        }

        if let color = CIFilter(name: "CIColorControls") {
            color.setValue(img, forKey: kCIInputImageKey)
            color.setValue(1.08, forKey: kCIInputSaturationKey)
            color.setValue(0.01, forKey: kCIInputBrightnessKey)
            color.setValue(1.14, forKey: kCIInputContrastKey)
            if let out = color.outputImage { img = out }
        }

        return img
    }

    private static func packRGB565LittleEndian(cgImage: CGImage, width: Int, height: Int) throws -> Data {
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var raw = [UInt8](repeating: 0, count: height * bytesPerRow)

        guard let cs = CGColorSpace(name: CGColorSpace.sRGB) else {
            throw SpotifyDisplayError.conversionFailed
        }

        var rasterizeFailed = false
        raw.withUnsafeMutableBytes { ptr in
            guard let base = ptr.baseAddress else {
                rasterizeFailed = true
                return
            }
            guard let ctx = CGContext(
                data: base,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: cs,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else {
                rasterizeFailed = true
                return
            }
            ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        if rasterizeFailed {
            throw SpotifyDisplayError.conversionFailed
        }

        var rBuf = [Float](repeating: 0, count: width * height)
        var gBuf = [Float](repeating: 0, count: width * height)
        var bBuf = [Float](repeating: 0, count: width * height)

        for y in 0..<height {
            let row = y * bytesPerRow
            for x in 0..<width {
                let o = row + x * 4
                let i = y * width + x
                rBuf[i] = Float(raw[o])
                gBuf[i] = Float(raw[o + 1])
                bBuf[i] = Float(raw[o + 2])
            }
        }

        var le = Data(count: width * height * 2)
        le.withUnsafeMutableBytes { out in
            guard let outBytes = out.bindMemory(to: UInt8.self).baseAddress else { return }

            for y in 0..<height {
                for x in 0..<width {
                    let i = y * width + x
                    let oldR = clamp8(rBuf[i])
                    let oldG = clamp8(gBuf[i])
                    let oldB = clamp8(bBuf[i])

                    let r5 = UInt16(oldR) >> 3
                    let g6 = UInt16(oldG) >> 2
                    let b5 = UInt16(oldB) >> 3
                    let packed = (r5 << 11) | (g6 << 5) | b5

                    let quantR = Float(Int(r5) * 255 / 31)
                    let quantG = Float(Int(g6) * 255 / 63)
                    let quantB = Float(Int(b5) * 255 / 31)

                    let errR = oldR - quantR
                    let errG = oldG - quantG
                    let errB = oldB - quantB

                    let base = i * 2
                    outBytes[base] = UInt8(truncatingIfNeeded: packed & 0xff)
                    outBytes[base + 1] = UInt8(truncatingIfNeeded: packed >> 8)

                    distributeAtkinsonError(&rBuf, x: x, y: y, width: width, height: height, error: errR)
                    distributeAtkinsonError(&gBuf, x: x, y: y, width: width, height: height, error: errG)
                    distributeAtkinsonError(&bBuf, x: x, y: y, width: width, height: height, error: errB)
                }
            }
        }
        return le
    }

    private static func clamp8(_ value: Float) -> Float {
        min(255.0, max(0.0, value))
    }

    private static func distributeAtkinsonError(
        _ channel: inout [Float],
        x: Int,
        y: Int,
        width: Int,
        height: Int,
        error: Float
    ) {
        let share = error / 8.0
        guard share != 0 else { return }
        addError(&channel, x: x + 1, y: y, width: width, height: height, error: share)
        addError(&channel, x: x + 2, y: y, width: width, height: height, error: share)
        addError(&channel, x: x - 1, y: y + 1, width: width, height: height, error: share)
        addError(&channel, x: x, y: y + 1, width: width, height: height, error: share)
        addError(&channel, x: x + 1, y: y + 1, width: width, height: height, error: share)
        addError(&channel, x: x, y: y + 2, width: width, height: height, error: share)
    }

    private static func addError(
        _ channel: inout [Float],
        x: Int,
        y: Int,
        width: Int,
        height: Int,
        error: Float
    ) {
        guard x >= 0, x < width, y >= 0, y < height else { return }
        let idx = y * width + x
        channel[idx] += error
    }
}
