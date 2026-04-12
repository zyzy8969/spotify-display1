import UIKit
import CoreImage
import CoreGraphics

/// sRGB-oriented resize + grade, packed little-endian RGB565, then Floyd–Steinberg (same algorithm as firmware used) for ESP32 (115_200 bytes).
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

        var rgb565 = try packRGB565LittleEndian(cgImage: output, width: 240, height: 240)
        applyFloydSteinbergDitheringRGB565(&rgb565, width: 240, height: 240)
        return rgb565
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

    /// Two-row Floyd–Steinberg matching the former `applyFloydSteinbergDithering` in `src/main.cpp` (RGB565 LE buffer).
    private static func applyFloydSteinbergDitheringRGB565(_ data: inout Data, width: Int, height: Int) {
        precondition(data.count == width * height * 2)
        data.withUnsafeMutableBytes { raw in
            let buffer = raw.bindMemory(to: UInt16.self).baseAddress!
            var errorBuf: [[Int16]] = [
                [Int16](repeating: 0, count: width * 3),
                [Int16](repeating: 0, count: width * 3),
            ]
            var currRow = 0
            var nextRow = 1

            for y in 0..<height {
                for x in 0..<width {
                    let idx = y * width + x
                    let pixel = buffer[idx]

                    var oldR = Int16(((pixel >> 11) & 0x1F) << 3)
                    var oldG = Int16(((pixel >> 5) & 0x3F) << 2)
                    var oldB = Int16((pixel & 0x1F) << 3)

                    oldR = oldR &+ errorBuf[currRow][x * 3]
                    oldG = oldG &+ errorBuf[currRow][x * 3 + 1]
                    oldB = oldB &+ errorBuf[currRow][x * 3 + 2]

                    oldR = min(255, max(0, oldR))
                    oldG = min(255, max(0, oldG))
                    oldB = min(255, max(0, oldB))

                    let newR = Int16((oldR >> 3) << 3)
                    let newG = Int16((oldG >> 2) << 2)
                    let newB = Int16((oldB >> 3) << 3)

                    let errR = oldR - newR
                    let errG = oldG - newG
                    let errB = oldB - newB

                    buffer[idx] = (UInt16(truncatingIfNeeded: Int(newR) >> 3) << 11)
                        | (UInt16(truncatingIfNeeded: Int(newG) >> 2) << 5)
                        | UInt16(truncatingIfNeeded: Int(newB) >> 3)

                    if x + 1 < width {
                        let xr = (Int32(errR) * 7) >> 4
                        let xg = (Int32(errG) * 7) >> 4
                        let xb = (Int32(errB) * 7) >> 4
                        errorBuf[currRow][(x + 1) * 3] += Int16(clamping: xr)
                        errorBuf[currRow][(x + 1) * 3 + 1] += Int16(clamping: xg)
                        errorBuf[currRow][(x + 1) * 3 + 2] += Int16(clamping: xb)
                    }

                    if y + 1 < height {
                        if x > 0 {
                            let xr = (Int32(errR) * 3) >> 4
                            let xg = (Int32(errG) * 3) >> 4
                            let xb = (Int32(errB) * 3) >> 4
                            errorBuf[nextRow][(x - 1) * 3] += Int16(clamping: xr)
                            errorBuf[nextRow][(x - 1) * 3 + 1] += Int16(clamping: xg)
                            errorBuf[nextRow][(x - 1) * 3 + 2] += Int16(clamping: xb)
                        }

                        let xr5 = (Int32(errR) * 5) >> 4
                        let xg5 = (Int32(errG) * 5) >> 4
                        let xb5 = (Int32(errB) * 5) >> 4
                        errorBuf[nextRow][x * 3] += Int16(clamping: xr5)
                        errorBuf[nextRow][x * 3 + 1] += Int16(clamping: xg5)
                        errorBuf[nextRow][x * 3 + 2] += Int16(clamping: xb5)

                        if x + 1 < width {
                            let xr1 = Int32(errR) >> 4
                            let xg1 = Int32(errG) >> 4
                            let xb1 = Int32(errB) >> 4
                            errorBuf[nextRow][(x + 1) * 3] += Int16(clamping: xr1)
                            errorBuf[nextRow][(x + 1) * 3 + 1] += Int16(clamping: xg1)
                            errorBuf[nextRow][(x + 1) * 3 + 2] += Int16(clamping: xb1)
                        }
                    }
                }

                swap(&currRow, &nextRow)
                errorBuf[nextRow] = [Int16](repeating: 0, count: width * 3)
            }
        }
    }
}
