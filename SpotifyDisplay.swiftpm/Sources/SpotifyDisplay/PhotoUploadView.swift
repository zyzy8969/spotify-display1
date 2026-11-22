import UIKit

/// Prepares a library photo for the display (BLE_PROTOCOL 1.12 display-only frame). The picker is the
/// photo icon in the main screen's header; there is no sheet. The whole photo is stretched to a square
/// (no crop), which `ImageProcessor` then resizes to 240x240 and dithers like a cover.
enum PhotoPrep {
    /// Keeps big library photos from filling memory; the display only needs 240 px.
    static func downscaled(_ image: UIImage, maxSide: CGFloat) -> UIImage {
        let longest = max(image.size.width, image.size.height)
        guard longest > maxSide else { return image }
        let scale = maxSide / longest
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }

    /// Renders `image` into a `side` x `side` square as JPEG, honouring its orientation. The whole photo
    /// is stretched to the square (owner's choice 2026-11-22: nothing cropped off, even if that changes
    /// its proportions), so `ImageProcessor`'s centre crop then has nothing left to cut.
    static func squareJPEG(from image: UIImage, side: CGFloat = 480) -> Data? {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format)
        let rendered = renderer.image { ctx in
            UIColor.black.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
            guard image.size.width > 0, image.size.height > 0 else { return }
            image.draw(in: CGRect(x: 0, y: 0, width: side, height: side))
        }
        return rendered.jpegData(compressionQuality: 0.92)
    }
}
