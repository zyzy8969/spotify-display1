import XCTest
import UIKit
@testable import SpotifyDisplay

/// Guards the two pieces that break silently: the SD cache key (a change misses, or mixes up, every
/// cover saved on the board) and the RGB565 bytes the display draws (a slip shows wrong colours).
final class CacheKeyAndPackingTests: XCTestCase {
    private var savedDither: String?

    override func setUp() {
        super.setUp()
        savedDither = UserDefaults.standard.string(forKey: DitherMode.storageKey)
    }

    override func tearDown() {
        UserDefaults.standard.set(savedDither, forKey: DitherMode.storageKey)
        super.tearDown()
    }

    func testCacheKeySourceStrings() {
        let url = "https://i.scdn.co/image/x"
        UserDefaults.standard.set(DitherMode.atkinson.rawValue, forKey: DitherMode.storageKey)
        XCTAssertEqual(String.cacheKeySource(albumId: "abc", imageURL: url), "album:abc|c=native")
        XCTAssertEqual(String.cacheKeySource(albumId: nil, imageURL: url), "url:\(url)|c=native")
        XCTAssertEqual(String.cacheKeySource(albumId: "", imageURL: url), "url:\(url)|c=native")

        // The dither picker is gone (2026-11-22): a choice stored by an older build is ignored, so the
        // keys stay Atkinson's and covers already on the card keep hitting.
        UserDefaults.standard.set(DitherMode.bayer.rawValue, forKey: DitherMode.storageKey)
        XCTAssertEqual(String.cacheKeySource(albumId: "abc", imageURL: url), "album:abc|c=native")

        // Per-mode suffixes, should a mode ever be selectable again.
        XCTAssertEqual(DitherMode.atkinson.cacheKeySuffix, "|c=native")
        XCTAssertEqual(DitherMode.bayer.cacheKeySuffix, "|c=native|d=bayer")
        XCTAssertEqual(DitherMode.off.cacheKeySuffix, "|c=native|d=none")
    }

    /// A photo's key is the MD5 of its bytes, so showing the same photo again is a cache hit.
    func testPhotoCacheKeySource() {
        let jpeg = Data("abc".utf8)  // md5("abc") = 900150983cd24fb0d6963f7d28e17f72
        XCTAssertEqual(String.photoCacheKeySource(jpeg: jpeg), "photo:900150983cd24fb0d6963f7d28e17f72|c=native")
    }

    func testMD5DigestMatchesPython() {
        // hashlib.md5(b"abc").hexdigest()
        let hex = "abc".md5Digest.map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(hex, "900150983cd24fb0d6963f7d28e17f72")
    }

    /// Pure red is exact in RGB565 (0xF800) in every dither mode, sent little-endian: 0x00, 0xF8.
    func testSolidRedPacksToLittleEndianF800() throws {
        let png = solidPNG(UIColor(red: 1, green: 0, blue: 0, alpha: 1), side: 300)
        let centre = (120 * 240 + 120) * 2  // clear of resize effects at the edges
        for mode in DitherMode.allCases {
            let out = try ImageProcessor.convertToRGB565(imageData: png, dither: mode)
            XCTAssertEqual(out.count, 115_200, "\(mode)")
            XCTAssertEqual(out[centre], 0x00, "\(mode)")
            XCTAssertEqual(out[centre + 1], 0xF8, "\(mode)")
        }
    }

    private func solidPNG(_ color: UIColor, side: CGFloat) -> Data {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.preferredRange = .standard  // plain sRGB, no wide-colour surprises
        let size = CGSize(width: side, height: side)
        return UIGraphicsImageRenderer(size: size, format: format).pngData { ctx in
            color.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }
    }
}
