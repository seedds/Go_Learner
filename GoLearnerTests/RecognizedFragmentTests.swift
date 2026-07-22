//
//  RecognizedFragmentTests.swift
//  GoLearnerTests
//
//  The recognized-fragment value type: placing an R×C fragment onto a full N×N
//  editor board at its anchor, plus the shared default side-to-move heuristic.
//  Pure value tests (no camera / Vision / engine).
//

import XCTest
@testable import GoLearner

final class RecognizedFragmentTests: XCTestCase {

    private func fragment(rows: Int, cols: Int,
                          black: [(Int, Int)] = [], white: [(Int, Int)] = [],
                          anchorX: Int, anchorY: Int) -> RecognizedFragment {
        var cells = [GoColor](repeating: .empty, count: rows * cols)
        for (c, r) in black { cells[r * cols + c] = .black }
        for (c, r) in white { cells[r * cols + c] = .white }
        return RecognizedFragment(rows: rows, cols: cols, cells: cells,
                                  anchorX: anchorX, anchorY: anchorY, confidence: 1)
    }

    func testPlacesFragmentAtTopLeft() {
        let f = fragment(rows: 2, cols: 2, black: [(0, 0)], white: [(1, 1)], anchorX: 0, anchorY: 0)
        let board = f.toEditorBoard(boardSize: 19)
        XCTAssertEqual(board.size, 19)
        XCTAssertEqual(board.color(x: 0, y: 0), .black)
        XCTAssertEqual(board.color(x: 1, y: 1), .white)
        XCTAssertEqual(board.color(x: 5, y: 5), .empty)
    }

    func testPlacesFragmentAtAnchor() {
        // A 3×3 corner fragment anchored to the bottom-right of a 19×19.
        let f = fragment(rows: 3, cols: 3, black: [(0, 0)], white: [(2, 2)],
                         anchorX: 16, anchorY: 16)
        let board = f.toEditorBoard(boardSize: 19)
        XCTAssertEqual(board.color(x: 16, y: 16), .black, "fragment (0,0) → board (16,16)")
        XCTAssertEqual(board.color(x: 18, y: 18), .white, "fragment (2,2) → board (18,18)")
    }

    func testOffBoardCellsAreDropped() {
        // Anchor near the edge so part of the fragment would fall off; those cells
        // are silently dropped rather than crashing.
        let f = fragment(rows: 3, cols: 3, black: [(0, 0), (2, 2)], anchorX: 17, anchorY: 17)
        let board = f.toEditorBoard(boardSize: 19)
        XCTAssertEqual(board.color(x: 17, y: 17), .black, "in-bounds cell placed")
        // (2,2) → (19,19) is off the 19×19 board → dropped, no crash.
        XCTAssertEqual(board.blackCount, 1)
    }

    func testDefaultToMoveMatchesHeuristic() {
        // Equal counts → Black.
        XCTAssertEqual(fragment(rows: 2, cols: 2, black: [(0, 0)], white: [(1, 1)],
                                anchorX: 0, anchorY: 0).defaultToMove, .black)
        // One extra black → White.
        XCTAssertEqual(fragment(rows: 2, cols: 2, black: [(0, 0), (1, 0)], white: [(1, 1)],
                                anchorX: 0, anchorY: 0).defaultToMove, .white)
        // Two extra black → ambiguous → Black.
        XCTAssertEqual(fragment(rows: 2, cols: 2, black: [(0, 0), (1, 0), (0, 1)],
                                anchorX: 0, anchorY: 0).defaultToMove, .black)
    }

    func testEditorBoardCarriesToMove() {
        let f = fragment(rows: 2, cols: 2, black: [(0, 0), (1, 0)], white: [(1, 1)],
                         anchorX: 3, anchorY: 3)
        let board = f.toEditorBoard(boardSize: 9)
        XCTAssertEqual(board.toMove, .white)     // 2 black vs 1 white
        XCTAssertEqual(board.color(x: 3, y: 3), .black)
    }
}
