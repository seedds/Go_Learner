//
//  HandicapPointsTests.swift
//  GoLearnerTests
//
//  Verifies the fixed handicap placement table: counts, star-point coordinates,
//  tengen for odd counts, and unsupported sizes/counts returning empty.
//

import XCTest

final class HandicapPointsTests: XCTestCase {

    private func set(_ pts: [SGFPoint]) -> Set<[Int]> {
        Set(pts.map { [$0.x, $0.y] })
    }

    func testCountsMatchHandicap() {
        for h in 2...9 {
            XCTAssertEqual(HandicapPoints.fixed(count: h, boardSize: 19).count, h, "H\(h)")
        }
    }

    func testTwoStonesAreOppositeCorners() {
        XCTAssertEqual(set(HandicapPoints.fixed(count: 2, boardSize: 19)),
                       set([SGFPoint(x: 15, y: 3), SGFPoint(x: 3, y: 15)]))
    }

    func testFourStonesAreTheFourStarCorners() {
        XCTAssertEqual(set(HandicapPoints.fixed(count: 4, boardSize: 19)),
                       set([SGFPoint(x: 3, y: 3), SGFPoint(x: 15, y: 3),
                            SGFPoint(x: 3, y: 15), SGFPoint(x: 15, y: 15)]))
    }

    func testOddCountsIncludeTengen() {
        for h in [5, 7, 9] {
            let pts = HandicapPoints.fixed(count: h, boardSize: 19)
            XCTAssertTrue(pts.contains(SGFPoint(x: 9, y: 9)), "H\(h) should include tengen")
        }
    }

    func testEvenSixAndEightSkipTengen() {
        for h in [6, 8] {
            let pts = HandicapPoints.fixed(count: h, boardSize: 19)
            XCTAssertFalse(pts.contains(SGFPoint(x: 9, y: 9)), "H\(h) should not include tengen")
        }
    }

    func testAllPointsAreOnStarLines() {
        let starLines: Set<Int> = [3, 9, 15]
        for h in 2...9 {
            for p in HandicapPoints.fixed(count: h, boardSize: 19) {
                XCTAssertTrue(starLines.contains(p.x) && starLines.contains(p.y),
                              "H\(h) point (\(p.x),\(p.y)) off star lines")
            }
        }
    }

    func testUnsupportedCountsAndSizesReturnEmpty() {
        XCTAssertTrue(HandicapPoints.fixed(count: 1, boardSize: 19).isEmpty)
        XCTAssertTrue(HandicapPoints.fixed(count: 10, boardSize: 19).isEmpty)
        XCTAssertTrue(HandicapPoints.fixed(count: 0, boardSize: 19).isEmpty)
        XCTAssertTrue(HandicapPoints.fixed(count: 4, boardSize: 13).isEmpty, "only 19×19 for now")
    }

    func testNoDuplicatePoints() {
        for h in 2...9 {
            let pts = HandicapPoints.fixed(count: h, boardSize: 19)
            XCTAssertEqual(set(pts).count, pts.count, "H\(h) has duplicates")
        }
    }
}
