//
//  FragmentAnalysisTests.swift
//  GoLearnerTests
//
//  The pure partial-board core: build a synthetic grayscale "fragment" (wood
//  background, thin dark grid lines within the fragment's extent, and dark/bright
//  stone discs at intersections) and assert the detected line count, stone
//  classification, and inferred anchor. Also unit-tests the anchor heuristic
//  directly. No Vision / Core Image / engine needed.
//

import XCTest
@testable import GoLearner

final class FragmentAnalysisTests: XCTestCase {

    /// Render a fragment into a `side`×`side` grayscale buffer: thin dark grid
    /// lines at the given `xs`/`ys` (drawn only within the fragment's extent, so
    /// the space beyond the outer lines is the empty margin the anchor heuristic
    /// reads), with stone discs painted on top at the requested intersections.
    private func synthetic(side: Int, xs: [Int], ys: [Int],
                           background: UInt8 = 180, lineLuma: UInt8 = 70,
                           black: [(Int, Int)] = [], white: [(Int, Int)] = []) -> GrayImage {
        var px = [UInt8](repeating: background, count: side * side)
        func setPx(_ x: Int, _ y: Int, _ v: UInt8) {
            if x >= 0, x < side, y >= 0, y < side { px[y * side + x] = v }
        }
        // Vertical lines span the fragment's row extent; horizontal lines its col
        // extent (3px wide so the ridge filter picks them up cleanly).
        if let y0 = ys.first, let y1 = ys.last {
            for x in xs { for y in y0...y1 { for d in -1...1 { setPx(x + d, y, lineLuma) } } }
        }
        if let x0 = xs.first, let x1 = xs.last {
            for y in ys { for x in x0...x1 { for d in -1...1 { setPx(x, y + d, lineLuma) } } }
        }
        let stepX = xs.count > 1 ? xs[1] - xs[0] : side
        let stepY = ys.count > 1 ? ys[1] - ys[0] : side
        let radius = max(2, Int(Double(min(stepX, stepY)) * 0.34))
        func disc(_ cx: Int, _ cy: Int, _ v: UInt8) {
            for y in max(0, cy - radius)...min(side - 1, cy + radius) {
                for x in max(0, cx - radius)...min(side - 1, cx + radius) {
                    let dx = x - cx, dy = y - cy
                    if dx * dx + dy * dy <= radius * radius { setPx(x, y, v) }
                }
            }
        }
        for (c, r) in black { disc(xs[c], ys[r], 25) }
        for (c, r) in white { disc(xs[c], ys[r], 245) }
        return GrayImage(width: side, height: side, pixels: px)
    }

    // MARK: - Line detection

    func testDetectsCenteredGridDimensions() {
        let img = synthetic(side: 540, xs: [120, 220, 320, 420], ys: [170, 270, 370])
        let frag = FragmentAnalysis.analyze(img, boardSize: 19)
        XCTAssertEqual(frag.cols, 4)
        XCTAssertEqual(frag.rows, 3)
        XCTAssertEqual(frag.cells.count, 12)
    }

    func testClassifiesFragmentStones() {
        let img = synthetic(side: 540, xs: [120, 220, 320, 420], ys: [170, 270, 370],
                            black: [(1, 1)], white: [(3, 2)])
        let frag = FragmentAnalysis.analyze(img, boardSize: 19)
        XCTAssertEqual(frag.cols, 4)
        XCTAssertEqual(frag.rows, 3)
        // index = r*cols + c
        XCTAssertEqual(frag.cells[1 * 4 + 1], .black, "black at (c1,r1)")
        XCTAssertEqual(frag.cells[2 * 4 + 3], .white, "white at (c3,r2)")
        XCTAssertEqual(frag.cells[0], .empty, "corner intersection is empty")
        XCTAssertEqual(frag.cells.filter { $0 == .black }.count, 1)
        XCTAssertEqual(frag.cells.filter { $0 == .white }.count, 1)
    }

    // MARK: - Anchor inference (end-to-end)

    func testTopLeftCornerAnchorsToOrigin() {
        // Large left/top margin (board edge), tight right/bottom (interior cut).
        let img = synthetic(side: 540, xs: [200, 360, 520], ys: [200, 360, 520],
                            black: [(0, 0)], white: [(2, 2)])
        let frag = FragmentAnalysis.analyze(img, boardSize: 19)
        XCTAssertEqual(frag.cols, 3)
        XCTAssertEqual(frag.rows, 3)
        XCTAssertEqual(frag.anchorX, 0)
        XCTAssertEqual(frag.anchorY, 0)
    }

    func testBottomRightCornerAnchorsToFarEdge() {
        // Tight left/top (interior cut), large right/bottom margin (board edge).
        let img = synthetic(side: 540, xs: [20, 180, 340], ys: [20, 180, 340])
        let frag = FragmentAnalysis.analyze(img, boardSize: 19)
        XCTAssertEqual(frag.cols, 3)
        XCTAssertEqual(frag.rows, 3)
        XCTAssertEqual(frag.anchorX, 16, "19 - 3 columns")
        XCTAssertEqual(frag.anchorY, 16)
    }

    // MARK: - Anchor heuristic (pure)

    func testAnchorIndexLowMarginEdge() {
        let a = FragmentAnalysis.anchorIndex(lineCount: 3, boardSize: 19,
                                             loMargin: 100, hiMargin: 5, step: 40, edgeFraction: 0.6)
        XCTAssertEqual(a, 0)
    }

    func testAnchorIndexHighMarginEdge() {
        let a = FragmentAnalysis.anchorIndex(lineCount: 3, boardSize: 19,
                                             loMargin: 5, hiMargin: 100, step: 40, edgeFraction: 0.6)
        XCTAssertEqual(a, 16)
    }

    func testAnchorIndexAmbiguousCenters() {
        // Both sides look like edges → centered.
        let a = FragmentAnalysis.anchorIndex(lineCount: 5, boardSize: 19,
                                             loMargin: 100, hiMargin: 100, step: 40, edgeFraction: 0.6)
        XCTAssertEqual(a, (19 - 5) / 2)
    }

    func testAnchorIndexClampsToBoard() {
        // A fragment as wide as the board can only anchor at 0.
        let a = FragmentAnalysis.anchorIndex(lineCount: 19, boardSize: 19,
                                             loMargin: 100, hiMargin: 5, step: 40, edgeFraction: 0.6)
        XCTAssertEqual(a, 0)
    }

    // MARK: - Degenerate inputs

    func testTinyImageReturnsEmptyFragment() {
        let img = GrayImage(width: 2, height: 2, pixels: [180, 180, 180, 180])
        let frag = FragmentAnalysis.analyze(img, boardSize: 19)
        XCTAssertEqual(frag.rows, 0)
        XCTAssertEqual(frag.cols, 0)
        XCTAssertEqual(frag.confidence, 0)
    }

    func testBlankImageFindsNoGrid() {
        let img = GrayImage(width: 300, height: 300, pixels: [UInt8](repeating: 180, count: 300 * 300))
        let frag = FragmentAnalysis.analyze(img, boardSize: 19)
        XCTAssertEqual(frag.rows, 0)
        XCTAssertEqual(frag.cols, 0)
    }
}
