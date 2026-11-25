import XCTest
import CoreGraphics
@testable import SpotifyDisplay

/// The BLE 1.25 animation payload: what the board inflates and plays.
final class AnimationPrepTests: XCTestCase {
    private let side = KeychainAnimation.side

    private func solidFrame(_ v: UInt16) -> Data {
        var d = Data(capacity: side * side * 2)
        for _ in 0..<(side * side) {
            d.append(UInt8(v & 0xFF))
            d.append(UInt8(v >> 8))
        }
        return d
    }

    func testRawPayloadIsDelaysThenFrames() {
        let a = KeychainAnimation(frames: [solidFrame(0x1234), solidFrame(0xABCD)],
                                  delaysMs: [100, 2000], posterJPEG: Data())
        let raw = a.rawPayload
        // Must match the firmware's check: count * 2 + count * side * side * 2.
        XCTAssertEqual(raw.count, 2 * 2 + 2 * side * side * 2)
        XCTAssertEqual(Array(raw.prefix(4)), [100, 0, 0xD0, 0x07])  // 100, 2000 as u16 LE
        XCTAssertEqual(raw[4], 0x34)
        XCTAssertEqual(raw[5], 0x12)
        XCTAssertEqual(raw[4 + side * side * 2], 0xCD)
        XCTAssertEqual(raw[5 + side * side * 2], 0xAB)
    }

    func testFirstFrameIsDoubledToFullSize() {
        var f = solidFrame(0)
        // Pixel (1, 0) of the 120 frame -> pixels (2..3, 0..1) of the 240 frame.
        f[2] = 0xEF
        f[3] = 0xBE
        let a = KeychainAnimation(frames: [f], delaysMs: [100], posterJPEG: Data())
        let full = a.firstFrame240
        XCTAssertEqual(full.count, 240 * 240 * 2)
        for (x, y) in [(2, 0), (3, 0), (2, 1), (3, 1)] {
            let i = (y * 240 + x) * 2
            XCTAssertEqual(full[i], 0xEF, "(\(x),\(y))")
            XCTAssertEqual(full[i + 1], 0xBE, "(\(x),\(y))")
        }
        XCTAssertEqual(full[(0 * 240 + 4) * 2], 0)
    }

    func testSamplingKeepsAtMostMax() {
        XCTAssertEqual(AnimationPrep.sampleIndices(count: 10, max: 48), Array(0..<10))
        let picks = AnimationPrep.sampleIndices(count: 100, max: 48)
        XCTAssertEqual(picks.count, 48)
        XCTAssertEqual(picks.first, 0)
        XCTAssertEqual(picks, picks.sorted())
        XCTAssertEqual(Set(picks).count, 48)
    }

    func testPackRoundsToNearest565() {
        // White, black, pure red, mid grey.
        let rgba: [UInt8] = [255, 255, 255, 255, 0, 0, 0, 255, 255, 0, 0, 255, 128, 128, 128, 255]
        let d = AnimationPrep.packRGB565(rgba, pixels: 4)
        func px(_ i: Int) -> UInt16 { UInt16(d[i * 2]) | UInt16(d[i * 2 + 1]) << 8 }
        XCTAssertEqual(px(0), 0xFFFF)
        XCTAssertEqual(px(1), 0x0000)
        XCTAssertEqual(px(2), 0xF800)
        XCTAssertEqual(px(3), UInt16(16 << 11 | 32 << 5 | 16))
    }

    func testBuildMakesHalfResFramesWithDelayFloor() throws {
        let cs = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let ctx = try XCTUnwrap(CGContext(data: nil, width: 200, height: 100, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: cs, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 200, height: 100))
        let image = try XCTUnwrap(ctx.makeImage())
        let a = try XCTUnwrap(AnimationPrep.build([
            .init(image: image, ms: 5),
            .init(image: image, ms: 120),
        ]))
        XCTAssertEqual(a.count, 2)
        XCTAssertEqual(a.frames[0].count, side * side * 2)
        XCTAssertEqual(a.delaysMs, [UInt16(KeychainAnimation.minDelayMs), 120])
        XCTAssertEqual(UInt16(a.frames[0][0]) | UInt16(a.frames[0][1]) << 8, 0x001F)  // blue
        XCTAssertFalse(a.posterJPEG.isEmpty)
    }

    /// The app's cover keeps each frame about as long as the keychain does.
    func testRepeatPlanKeepsFrameTiming() {
        let plan = KeychainAnimation.repeatPlan(delaysMs: [100, 200, 50])
        XCTAssertEqual(plan.unitMs, 50)
        XCTAssertEqual(plan.repeats, [2, 4, 1])
        // A long GIF gets a coarser unit instead of thousands of slots.
        let long = KeychainAnimation.repeatPlan(delaysMs: Array(repeating: 40, count: 48) + [5000], maxSlots: 240)
        XCTAssertLessThanOrEqual(long.repeats.reduce(0, +), 260)
        XCTAssertTrue(long.repeats.allSatisfy { $0 >= 1 })
    }

    func testPreviewImageAnimates() throws {
        let a = KeychainAnimation(frames: [solidFrame(0xF800), solidFrame(0x001F)],
                                  delaysMs: [100, 300], posterJPEG: Data())
        let image = try XCTUnwrap(a.previewImage())
        XCTAssertEqual(image.images?.count, 4)  // 1 + 3 slots of 100 ms
        XCTAssertEqual(image.duration, 0.4, accuracy: 0.001)
    }

    /// GIF frames use the fixed Bayer pattern: black and white stay pure, a mid grey mixes neighbouring
    /// 565 levels, and the same picture always gives the same bytes (no frame-to-frame crawl).
    func testBayerKeepsExtremesAndIsStable() {
        let side = 8
        func solid(_ v: UInt8) -> [UInt8] { (0..<(side * side)).flatMap { _ in [v, v, v, 255] } }
        func px(_ d: Data, _ i: Int) -> UInt16 { UInt16(d[i * 2]) | UInt16(d[i * 2 + 1]) << 8 }
        let white = AnimationPrep.packRGB565Bayer(solid(255), side: side)
        let black = AnimationPrep.packRGB565Bayer(solid(0), side: side)
        XCTAssertTrue((0..<(side * side)).allSatisfy { px(white, $0) == 0xFFFF })
        XCTAssertTrue((0..<(side * side)).allSatisfy { px(black, $0) == 0x0000 })
        let grey = AnimationPrep.packRGB565Bayer(solid(130), side: side)
        XCTAssertGreaterThan(Set((0..<(side * side)).map { px(grey, $0) }).count, 1)
        XCTAssertEqual(grey, AnimationPrep.packRGB565Bayer(solid(130), side: side))
    }

    /// The raw payload must fit the board's 2 MiB buffer at the app's frame cap.
    func testWorstCasePayloadFitsBoardBuffer() {
        let worst = KeychainAnimation.maxFrames * 2 + KeychainAnimation.maxFrames * side * side * 2
        XCTAssertLessThanOrEqual(worst, 2 * 1024 * 1024)
    }
}
