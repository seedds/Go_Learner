//
//  BoardImageAnalysisTests.swift
//  GoLearnerTests
//
//  The pure heuristic classifier: build a synthetic grayscale "board" (wood
//  background with dark/bright discs at known intersections) and assert each
//  intersection is read as empty / black / white. No Vision / Core Image needed.
//

import XCTest
@testable import GoLearner

final class BoardImageAnalysisTests: XCTestCase {

    /// Render a `size`×`size` board into a `side`×`side` grayscale buffer: a wood
    /// background with a filled disc at each requested stone (dark for black,
    /// bright for white), centered on the grid intersections spanning the buffer.
    private func synthetic(size: Int, side: Int,
                           background: UInt8 = 180,
                           black: [(Int, Int)] = [], white: [(Int, Int)] = []) -> GrayImage {
        var px = [UInt8](repeating: background, count: side * side)
        let centers = BoardImageAnalysis.axisCenters(count: size, extent: side, inset: 0)
        let step = size > 1 ? (centers[1] - centers[0]) : side
        let radius = max(2, Int(Double(step) * 0.34))

        func disc(_ cx: Int, _ cy: Int, _ value: UInt8) {
            for y in max(0, cy - radius)...min(side - 1, cy + radius) {
                for x in max(0, cx - radius)...min(side - 1, cx + radius) {
                    let dx = x - cx, dy = y - cy
                    if dx * dx + dy * dy <= radius * radius { px[y * side + x] = value }
                }
            }
        }
        for (gx, gy) in black { disc(centers[gx], centers[gy], 25) }
        for (gx, gy) in white { disc(centers[gx], centers[gy], 245) }
        return GrayImage(width: side, height: side, pixels: px)
    }

    private func at(_ cells: [GoColor], _ x: Int, _ y: Int, size: Int) -> GoColor {
        cells[y * size + x]
    }

    func testEmptyBoardClassifiesAllEmpty() {
        let img = synthetic(size: 19, side: 760)
        let cells = BoardImageAnalysis.classify(img, size: 19)
        XCTAssertEqual(cells.count, 19 * 19)
        XCTAssertTrue(cells.allSatisfy { $0 == .empty })
    }

    func testClassifiesBlackAndWhiteStones() {
        let black = [(3, 3), (15, 3), (9, 9)]
        let white = [(3, 15), (15, 15)]
        let img = synthetic(size: 19, side: 760, black: black, white: white)
        let cells = BoardImageAnalysis.classify(img, size: 19)

        for (x, y) in black {
            XCTAssertEqual(at(cells, x, y, size: 19), .black, "expected black at (\(x),\(y))")
        }
        for (x, y) in white {
            XCTAssertEqual(at(cells, x, y, size: 19), .white, "expected white at (\(x),\(y))")
        }
        // A few known-empty points.
        XCTAssertEqual(at(cells, 0, 0, size: 19), .empty)
        XCTAssertEqual(at(cells, 10, 0, size: 19), .empty)
        XCTAssertEqual(cells.filter { $0 == .black }.count, black.count)
        XCTAssertEqual(cells.filter { $0 == .white }.count, white.count)
    }

    func testWorksOnNineByNine() {
        let black = [(2, 2), (4, 4)]
        let white = [(6, 6)]
        let img = synthetic(size: 9, side: 540, black: black, white: white)
        let cells = BoardImageAnalysis.classify(img, size: 9)
        XCTAssertEqual(at(cells, 2, 2, size: 9), .black)
        XCTAssertEqual(at(cells, 4, 4, size: 9), .black)
        XCTAssertEqual(at(cells, 6, 6, size: 9), .white)
        XCTAssertEqual(at(cells, 0, 0, size: 9), .empty)
    }

    func testAxisCentersSpanExtent() {
        let c = BoardImageAnalysis.axisCenters(count: 19, extent: 760, inset: 0)
        XCTAssertEqual(c.count, 19)
        XCTAssertEqual(c.first, 0)
        XCTAssertEqual(c.last, 759)
        // Monotonic increasing.
        XCTAssertTrue(zip(c, c.dropFirst()).allSatisfy { $0 < $1 })
    }

    func testMedianBackgroundRobustToManyStones() {
        // Even with a dense board the wood background still dominates enough
        // intersections for the median to land on it.
        var black: [(Int, Int)] = []
        for i in 0..<9 { black.append((i, 0)) }   // a full row of black
        let img = synthetic(size: 9, side: 540, black: black)
        let cells = BoardImageAnalysis.classify(img, size: 9)
        for x in 0..<9 {
            XCTAssertEqual(at(cells, x, 0, size: 9), .black, "row 0 col \(x)")
        }
        XCTAssertEqual(at(cells, 4, 4, size: 9), .empty)
    }
}
