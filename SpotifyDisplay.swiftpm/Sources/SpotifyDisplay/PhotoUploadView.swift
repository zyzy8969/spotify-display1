import UIKit
import ImageIO

/// Prepares a library photo for the display (BLE_PROTOCOL 1.12 display-only frame). The picker is the
/// photo icon in the main screen's header; there is no sheet. The whole photo is stretched to a square
/// (no crop), which `ImageProcessor` then resizes to 240x240 and dithers like a cover.
enum PhotoPrep {
    /// Library photo bytes (JPEG / HEIC / PNG) -> `side` x `side` square JPEG, or nil if unreadable.
    /// ImageIO decodes straight to a small thumbnail (orientation applied) instead of decoding the full
    /// 12+ MP photo and drawing it twice; that full decode ran on the main thread and froze the screen.
    /// Call it off the main thread. The whole photo is stretched to the square (owner's choice
    /// 2026-11-22: nothing cropped off, even if that changes its proportions).
    static func squareJPEG(fromPhotoData data: Data, side: CGFloat = 480) -> Data? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else { return nil }
        let thumbOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,  // honour the EXIF orientation
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(side * 2),
        ] as CFDictionary
        guard let thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions),
              thumb.width > 0, thumb.height > 0 else { return nil }

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format)
        let rendered = renderer.image { _ in
            UIImage(cgImage: thumb).draw(in: CGRect(x: 0, y: 0, width: side, height: side))
        }
        return rendered.jpegData(compressionQuality: 0.92)
    }
}
