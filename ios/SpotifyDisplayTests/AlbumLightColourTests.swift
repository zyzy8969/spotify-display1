import XCTest
@testable import SpotifyDisplay

/// The BLE 1.23 "album" song light: one LED colour per cover.
final class AlbumLightColourTests: XCTestCase {
    /// A 240x240 LE RGB565 frame; `pixel(i)` gives each pixel's 16-bit colour.
    private func frame(_ pixel: (Int) -> UInt16) -> Data {
        var d = Data(capacity: 240 * 240 * 2)
        for i in 0..<(240 * 240) {
            let v = pixel(i)
            d.append(UInt8(v & 0xFF))
            d.append(UInt8(v >> 8))
        }
        return d
    }

    private func channels(_ hex: UInt32) -> (Int, Int, Int) {
        (Int(hex >> 16 & 0xFF), Int(hex >> 8 & 0xFF), Int(hex & 0xFF))
    }

    func testSolidRedIsRed() {
        let (r, g, b) = channels(AlbumLightColour.from(rgb565: frame { _ in 0xF800 }))
        XCTAssertEqual(r, 255)
        XCTAssertLessThan(g, 40)
        XCTAssertLessThan(b, 40)
    }

    func testBlackAndWhiteCoverIsWhite() {
        let hex = AlbumLightColour.from(rgb565: frame { i in (i / 240) % 2 == 0 ? 0x0000 : 0xFFFF })
        XCTAssertEqual(hex, AlbumLightColour.grey)
    }

    /// A small vivid patch on a mostly black cover still wins: the LED gets the cover's colour, not black.
    func testVividPatchBeatsDarkBackground() {
        let hex = AlbumLightColour.from(rgb565: frame { i in (i % 240) < 40 ? 0x001F : 0x0841 })
        let (r, g, b) = channels(hex)
        XCTAssertEqual(b, 255)
        XCTAssertLessThan(r, 120)
        XCTAssertLessThan(g, 120)
    }

    /// Owner, 2026-11-24: the biggest colour area wins, even over a smaller, more vivid one.
    func testBiggestAreaBeatsMoreVividPatch() {
        // 80% muted red (r 24/31, g 20/63, b 10/31), 20% pure blue.
        let hex = AlbumLightColour.from(rgb565: frame { i in (i % 240) < 192 ? 0xC28A : 0x001F })
        let (r, _, b) = channels(hex)
        XCTAssertEqual(r, 255)
        XCTAssertLessThan(b, 120)
    }

    /// Under 3% coloured: a small logo on black still sets the colour (vivid fallback), not white.
    func testSmallLogoOnBlackUsesLogoColour() {
        let hex = AlbumLightColour.from(rgb565: frame { i in (i % 240) < 4 ? 0xF800 : 0x0000 })
        let (r, g, b) = channels(hex)
        XCTAssertEqual(r, 255)
        XCTAssertLessThan(g, 40)
        XCTAssertLessThan(b, 40)
    }

    /// The LED's PWM is linear: a mid screen value must come out much lower (gamma 2.2), full stays full.
    func testLedGamma() {
        XCTAssertEqual(AlbumLightColour.ledGamma(0xFF8000), 0xFF3800)
        XCTAssertEqual(AlbumLightColour.ledGamma(0xFFFFFF), 0xFFFFFF)
        XCTAssertEqual(AlbumLightColour.ledGamma(0x000000), 0x000000)
    }

    func testEmptyFrameIsWhite() {
        XCTAssertEqual(AlbumLightColour.from(rgb565: Data()), AlbumLightColour.grey)
    }
}
