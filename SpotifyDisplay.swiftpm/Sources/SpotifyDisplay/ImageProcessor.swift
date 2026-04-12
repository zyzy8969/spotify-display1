import UIKit
import CoreImage
import CoreGraphics

/// sRGB-oriented resize + grade, then packed little-endian RGB565 for ESP32 (115_200 bytes).
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

        if let gamma = CIFilter(name: "CIGammaAdjust") {
            gamma.setValue(img, forKey: kCIInputImageKey)
            gamma.setValue(0.89, forKey: "inputPower")
            if let out = gamma.outputImage { img = out }
        }

        if let color = CIFilter(name: "CIColorControls") {
            color.setValue(img, forKey: kCIInputImageKey)
            color.setValue(1.1, forKey: kCIInputSaturationKey)
            color.setValue(0.02, forKey: kCIInputBrightnessKey)
            color.setValue(1.12, forKey: kCIInputContrastKey)
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

        var le = Data()
        le.reserveCapacity(width * height * 2)
        for y in 0..<height {
            let row = y * bytesPerRow
            for x in 0..<width {
                let o = row + x * 4
                let r5 = UInt16(raw[o]) >> 3
                let g6 = UInt16(raw[o + 1]) >> 2
                let b5 = UInt16(raw[o + 2]) >> 3
                let v = (r5 << 11) | (g6 << 5) | b5
                le.append(UInt8(truncatingIfNeeded: v & 0xff))
                le.append(UInt8(truncatingIfNeeded: v >> 8))
            }
        }
        return le
    }
}
