//
//  HandicapPointsTests.swift
//  GoLearnerTests
//
//  Verifies the fixed handicap placement table: counts, star-point coordinates,
//  tengen for odd counts, and unsupported sizes/counts returning empty.
//

import XCTest
@testable import GoLearner

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
        // Boards below 7 have no fixed-handicap layout (matches the engine).
        XCTAssertTrue(HandicapPoints.fixed(count: 2, boardSize: 6).isEmpty)
    }

    func testNoDuplicatePoints() {
        for n in [9, 13, 19] {
            for h in 2...9 {
                let pts = HandicapPoints.fixed(count: h, boardSize: n)
                XCTAssertEqual(set(pts).count, pts.count, "\(n): H\(h) has duplicates")
            }
        }
    }

    // MARK: Sub-19 placement (must match the engine's PlayUtils::placeFixedHandicap)

    func testNineByNineCornersAndTengen() {
        // near=2, far=6, mid=4 for a 9×9 board.
        XCTAssertEqual(set(HandicapPoints.fixed(count: 4, boardSize: 9)),
                       set([SGFPoint(x: 2, y: 2), SGFPoint(x: 6, y: 2),
                            SGFPoint(x: 2, y: 6), SGFPoint(x: 6, y: 6)]))
        XCTAssertTrue(HandicapPoints.fixed(count: 5, boardSize: 9).contains(SGFPoint(x: 4, y: 4)),
                      "H5 on 9×9 should include tengen (4,4)")
    }

    func testThirteenByThirteenCorners() {
        // near=3, far=9, mid=6 for a 13×13 board.
        XCTAssertEqual(set(HandicapPoints.fixed(count: 4, boardSize: 13)),
                       set([SGFPoint(x: 3, y: 3), SGFPoint(x: 9, y: 3),
                            SGFPoint(x: 3, y: 9), SGFPoint(x: 9, y: 9)]))
    }

    func testCountsMatchHandicapAcrossSizes() {
        for n in [9, 13, 19] {
            for h in 2...9 {
                XCTAssertEqual(HandicapPoints.fixed(count: h, boardSize: n).count, h, "\(n): H\(h)")
            }
        }
    }

    func testSubNineteenPointsAreOnBoard() {
        for n in [9, 13] {
            for h in 2...9 {
                for p in HandicapPoints.fixed(count: h, boardSize: n) {
                    XCTAssertTrue((0..<n).contains(p.x) && (0..<n).contains(p.y),
                                  "\(n): H\(h) point (\(p.x),\(p.y)) off board")
                }
            }
        }
    }
}
