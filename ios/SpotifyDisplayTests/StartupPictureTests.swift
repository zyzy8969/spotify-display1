import XCTest
@testable import SpotifyDisplay

/// Starred photos (Photos page) and the start-up picture's random pick.
@MainActor
final class StartupPictureTests: XCTestCase {
    /// Deterministic generator so the pick tests are repeatable (SplitMix64).
    private struct SeededRNG: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    private func item(_ id: String, starred: Bool = false) -> PhotoLibrary.Item {
        PhotoLibrary.Item(id: id, added: Date(timeIntervalSinceReferenceDate: 0), favorite: starred ? true : nil)
    }

    // MARK: Favourite persistence

    func testIndexSavedBeforeStarsStillDecodes() throws {
        let old = #"[{"id":"aa","added":0},{"id":"bb","added":10}]"#
        let items = try JSONDecoder().decode([PhotoLibrary.Item].self, from: Data(old.utf8))
        XCTAssertEqual(items.map(\.id), ["aa", "bb"])
        XCTAssertFalse(items[0].isFavorite)
        XCTAssertNil(items[1].favorite)
    }

    func testStarSurvivesEncodeDecode() throws {
        let saved = [item("aa", starred: true), item("bb")]
        let data = try JSONEncoder().encode(saved)
        let back = try JSONDecoder().decode([PhotoLibrary.Item].self, from: data)
        XCTAssertEqual(back, saved)
        XCTAssertTrue(back[0].isFavorite)
        XCTAssertFalse(back[1].isFavorite)
    }

    // MARK: Cap

    func testCapDropsOldestUnstarredFirst() {
        // Newest first: "d" is the oldest, but starred.
        let items = [item("a"), item("b"), item("c"), item("d", starred: true)]
        let (kept, dropped) = PhotoLibrary.trimmed(items, cap: 2)
        XCTAssertEqual(kept.map(\.id), ["a", "d"])
        XCTAssertEqual(dropped.map(\.id), ["c", "b"])
    }

    func testCapDropsOldestStarredOnlyWhenAllStarred() {
        let items = [item("a", starred: true), item("b", starred: true), item("c", starred: true)]
        let (kept, dropped) = PhotoLibrary.trimmed(items, cap: 2)
        XCTAssertEqual(kept.map(\.id), ["a", "b"])
        XCTAssertEqual(dropped.map(\.id), ["c"])
    }

    func testUnderCapKeepsEverything() {
        let items = [item("a"), item("b", starred: true)]
        let (kept, dropped) = PhotoLibrary.trimmed(items, cap: 60)
        XCTAssertEqual(kept, items)
        XCTAssertTrue(dropped.isEmpty)
    }

    // MARK: Random pick

    func testNoStarsPicksNothing() {
        var rng = SeededRNG(state: 1)
        XCTAssertNil(PhotoLibrary.pickStartup(from: [], last: nil, using: &rng))
        XCTAssertNil(PhotoLibrary.pickStartup(from: [], last: "a", using: &rng))
    }

    func testSingleStarIsShownEveryTime() {
        var rng = SeededRNG(state: 2)
        XCTAssertEqual(PhotoLibrary.pickStartup(from: ["a"], last: nil, using: &rng), "a")
        XCTAssertEqual(PhotoLibrary.pickStartup(from: ["a"], last: "a", using: &rng), "a")
    }

    func testNeverRepeatsLastPickWithTwoOrMore() {
        var rng = SeededRNG(state: 3)
        let ids = ["a", "b", "c"]
        var last: String?
        var seen = Set<String>()
        for _ in 0..<300 {
            guard let pick = PhotoLibrary.pickStartup(from: ids, last: last, using: &rng) else {
                return XCTFail("no pick")
            }
            XCTAssertNotEqual(pick, last)
            XCTAssertTrue(ids.contains(pick))
            seen.insert(pick)
            last = pick
        }
        XCTAssertEqual(seen, Set(ids), "every starred photo comes up")
    }

    func testTwoStarsAlternate() {
        var rng = SeededRNG(state: 4)
        var last: String? = "a"
        for _ in 0..<20 {
            let pick = PhotoLibrary.pickStartup(from: ["a", "b"], last: last, using: &rng)
            XCTAssertNotEqual(pick, last)
            last = pick
        }
    }

    func testLastPickThatWasUnstarredDoesNotBlock() {
        var rng = SeededRNG(state: 5)
        // "z" was shown last time but has since been unstarred or removed.
        let pick = PhotoLibrary.pickStartup(from: ["a"], last: "z", using: &rng)
        XCTAssertEqual(pick, "a")
    }
}
