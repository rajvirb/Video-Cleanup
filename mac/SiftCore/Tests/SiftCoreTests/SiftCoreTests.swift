import XCTest
@testable import SiftCore

final class FingerprintTests: XCTestCase {
    /// A test picture: soft diagonal bands, with a bright square.
    func picture(_ w: Int, _ h: Int, shift: Double = 0, brighten: Double = 0) -> [UInt8] {
        var px = [UInt8](repeating: 0, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                let fx = Double(x) / Double(w), fy = Double(y) / Double(h)
                var v = 128 + 90 * sin((fx * 5 + fy * 3 + shift) * .pi) + brighten
                if fx > 0.6 && fx < 0.8 && fy > 0.2 && fy < 0.45 { v += 60 }
                px[y * w + x] = UInt8(max(0, min(255, v)))
            }
        }
        return px
    }

    func testSamePictureAtDifferentSizesMatches() throws {
        let big = try XCTUnwrap(Fingerprint.hash(gray: picture(320, 240), width: 320, height: 240))
        let small = try XCTUnwrap(Fingerprint.hash(gray: picture(160, 120), width: 160, height: 120))
        XCTAssertLessThanOrEqual(Fingerprint.distance(big, small), 12)
        let brighter = try XCTUnwrap(Fingerprint.hash(gray: picture(320, 240, brighten: 20), width: 320, height: 240))
        XCTAssertLessThanOrEqual(Fingerprint.distance(big, brighter), 12, "a brightness change barely matters")
    }

    func testDifferentPicturesDiffer() throws {
        let a = try XCTUnwrap(Fingerprint.hash(gray: picture(200, 150), width: 200, height: 150))
        var noise = SystemRandomNumberGenerator()
        let other = (0..<(200 * 150)).map { _ in UInt8.random(in: 0...255, using: &noise) }
        let b = try XCTUnwrap(Fingerprint.hash(gray: other, width: 200, height: 150))
        XCTAssertGreaterThan(Fingerprint.distance(a, b), 80)
    }

    func testBlankPicturesHaveNoFingerprint() {
        XCTAssertNil(Fingerprint.hash(gray: [UInt8](repeating: 77, count: 100 * 80), width: 100, height: 80))
    }

    func testBoxResizeAverages() {
        // a 4×2 image of two flat halves shrinks to their averages
        let px = Fingerprint.boxResize(gray: [0, 0, 200, 200, 0, 0, 200, 200], width: 4, height: 2, toWidth: 2, toHeight: 1)
        XCTAssertEqual(px, [0, 200])
        // partly covered pixels count in proportion
        let third = Fingerprint.boxResize(gray: [0, 90, 180], width: 3, height: 1, toWidth: 2, toHeight: 1)
        XCTAssertEqual(third[0], 30, accuracy: 0.001)
        XCTAssertEqual(third[1], 150, accuracy: 0.001)
    }
}

final class MatchingTests: XCTestCase {
    let t = Date(timeIntervalSinceReferenceDate: 742_000_000)
    let base: [UInt64] = [0x0123_4567_89AB_CDEF, 0xFEDC_BA98_7654_3210, 0x0F0F_0F0F_F0F0_F0F0, 0x3333_5555_AAAA_CCCC]

    /// base with the first `bits` bits flipped
    func flip(_ h: [UInt64], _ bits: Int, from start: Int = 0) -> [UInt64] {
        var h = h
        for b in start..<(start + bits) { h[b / 64] ^= 1 << UInt64(63 - b % 64) }
        return h
    }

    /// The same mix the Python version was tested with: copies, a copy saved from a
    /// message, bursts, retakes and an unrelated photo.
    func library() -> [PhotoItem] {
        let other: [UInt64] = base.map { ~$0 }
        return [
            PhotoItem(id: "original", name: "original", date: t, width: 2048, height: 1365, size: 554_000, hash: base),
            PhotoItem(id: "identical", name: "identical copy", date: t, width: 2048, height: 1365, size: 554_000, hash: flip(base, 2)),
            PhotoItem(id: "resized", name: "resized copy", date: t.addingTimeInterval(0.2), width: 1024, height: 682, size: 100_000, hash: flip(base, 8)),
            PhotoItem(id: "message", name: "saved from a message", date: t.addingTimeInterval(3 * 86400), width: 1024, height: 682, size: 100_000, hash: flip(base, 8)),
            PhotoItem(id: "burst1", name: "burst 1", date: t.addingTimeInterval(9000), width: 4032, height: 3024, size: 3_000_000, burst: true, hash: flip(other, 3)),
            PhotoItem(id: "burst2", name: "burst 2", date: t.addingTimeInterval(9000.2), width: 4032, height: 3024, size: 3_100_000, burst: true, hash: flip(other, 6)),
            PhotoItem(id: "retake", name: "retake", date: t.addingTimeInterval(9002.6), width: 4032, height: 3024, size: 3_050_000, hash: flip(other, 28)),
            PhotoItem(id: "fav", name: "favourite retake", date: t.addingTimeInterval(9001), width: 4032, height: 3024, size: 2_900_000, favorite: true, hash: other),
            PhotoItem(id: "unrelated", name: "unrelated", date: t, width: 4032, height: 3024, size: 2_000_000, hash: flip(base, 128, from: 64)),
        ]
    }

    func describe(_ sets: [DuplicateSet], _ items: [PhotoItem]) -> [[String]] {
        sets.map { $0.members.map { "\(items[$0.index].id):\($0.suggestion.rawValue)" } }
    }

    func testStrictOnlyFindsCopies() {
        let items = library()
        let sets = Grouping.buildSets(items, matches: Matcher.findPhotoMatches(items, strictness: .strict))
        XCTAssertEqual(describe(sets, items), [["original:keep", "identical:delete", "resized:delete", "message:review"]])
        XCTAssertEqual(sets[0].saving(items), 654_000)
    }

    func testBalancedAddsBurstsAndRetakesForReview() {
        let items = library()
        let sets = Grouping.buildSets(items, matches: Matcher.findPhotoMatches(items, strictness: .balanced))
        XCTAssertEqual(sets.count, 2)
        XCTAssertEqual(describe(sets, items)[0], ["original:keep", "identical:delete", "resized:delete", "message:review"])
        let shots = describe(sets, items)[1]
        XCTAssertEqual(shots.first, "fav:keep", "same resolution: the favourite wins")
        XCTAssertEqual(Set(shots.dropFirst()), ["burst1:review", "burst2:review", "retake:review"],
                       "bursts and retakes are never suggested for deleting")
    }

    func testMatchKinds() {
        let items = library()
        let kinds = Dictionary(uniqueKeysWithValues: Matcher.findPhotoMatches(items, strictness: .balanced)
            .map { ("\(items[$0.a].id)-\(items[$0.b].id)", $0.kind) })
        XCTAssertEqual(kinds["original-identical"], .identical)
        XCTAssertEqual(kinds["original-resized"], .same)
        XCTAssertEqual(kinds["original-message"], .lookalike)
        XCTAssertEqual(kinds["burst1-burst2"], .similar, "bursts are never copies, however alike")
        XCTAssertNil(kinds["original-unrelated"])
    }

    func testFavouritesAreNeverSuggestedForDeleting() {
        var items = library()
        items[2].favorite = true                         // the resized copy (it can't win: lower resolution)
        let sets = Grouping.buildSets(items, matches: Matcher.findPhotoMatches(items, strictness: .strict))
        XCTAssertEqual(items[sets[0].keeper].id, "original")
        let member = sets[0].members.first { items[$0.index].id == "resized" }!
        XCTAssertEqual(member.suggestion, .review)
        XCTAssertTrue(member.reason.hasSuffix("(but it's a favourite)"))
    }

    func testSetsWithMostSpaceFirst() {
        var items = library()
        items.append(PhotoItem(id: "huge", name: "huge", date: t.addingTimeInterval(50_000), width: 8000, height: 6000,
                               size: 40_000_000, hash: flip(base, 32, from: 160)))
        items.append(PhotoItem(id: "huge copy", name: "huge copy", date: t.addingTimeInterval(50_000), width: 4000, height: 3000,
                               size: 9_000_000, hash: flip(flip(base, 32, from: 160), 4)))
        let sets = Grouping.buildSets(items, matches: Matcher.findPhotoMatches(items, strictness: .strict))
        XCTAssertEqual(items[sets[0].keeper].id, "huge")
    }
}

final class FormatTests: XCTestCase {
    func testSizes() {
        XCTAssertEqual(Format.size(999), "999 B")
        XCTAssertEqual(Format.size(554_000), "554 KB")
        XCTAssertEqual(Format.size(337_400_000), "337.4 MB")
        XCTAssertEqual(Format.size(1_400_000_000), "1.4 GB")
    }

    func testTimeLeft() {
        XCTAssertNil(Format.timeLeft(spent: 2, done: 10, total: 100))
        XCTAssertEqual(Format.timeLeft(spent: 40, done: 2400, total: 8000), "about 2 minutes left")
    }
}
