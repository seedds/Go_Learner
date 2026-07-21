//
//  RecognizedBoardTests.swift
//  GoLearnerTests
//
//  The recognized-board value type: stone counts, the default side-to-move
//  heuristic, and the hand-off to the editor. Pure value tests (no camera /
//  Vision / engine).
//

import XCTest
@testable import GoLearner

final class RecognizedBoardTests: XCTestCase {

    private func board(size: Int, black: [(Int, Int)], white: [(Int, Int)]) -> RecognizedBoard {
        var cells = [GoColor](repeating: .empty, count: size * size)
        for (x, y) in black { cells[y * size + x] = .black }
        for (x, y) in white { cells[y * size + x] = .white }
        return RecognizedBoard(size: size, cells: cells, confidence: 1)
    }

    func testCounts() {
        let b = board(size: 19, black: [(0, 0), (1, 1)], white: [(2, 2)])
        XCTAssertEqual(b.blackCount, 2)
        XCTAssertEqual(b.whiteCount, 1)
    }

    func testDefaultToMoveEqualCountsIsBlack() {
        let b = board(size: 19, black: [(0, 0)], white: [(1, 1)])
        XCTAssertEqual(b.defaultToMove, .black)
    }

    func testDefaultToMoveOneExtraBlackIsWhite() {
        let b = board(size: 19, black: [(0, 0), (1, 1)], white: [(2, 2)])
        XCTAssertEqual(b.defaultToMove, .white)
    }

    func testDefaultToMoveAmbiguousFallsBackToBlack() {
        // Two extra black stones (e.g. a handicap) is ambiguous → Black.
        let b = board(size: 19, black: [(0, 0), (1, 1), (2, 2)], white: [])
        XCTAssertEqual(b.defaultToMove, .black)
    }

    func testMismatchedCellCountYieldsEmptyBoard() {
        let b = RecognizedBoard(size: 19, cells: [.black, .white], confidence: 0)
        XCTAssertEqual(b.cells.count, 19 * 19)
        XCTAssertEqual(b.blackCount, 0)
    }

    func testToEditorBoardCarriesStonesAndTurn() {
        let b = board(size: 13, black: [(3, 3), (4, 4)], white: [(9, 9)])
        let editor = b.toEditorBoard()
        XCTAssertEqual(editor.size, 13)
        XCTAssertEqual(editor.color(x: 3, y: 3), .black)
        XCTAssertEqual(editor.color(x: 9, y: 9), .white)
        // 2 black vs 1 white → White to move by the heuristic.
        XCTAssertEqual(editor.toMove, .white)
        // And it converts on to a setup unchanged.
        XCTAssertEqual(editor.toSetup().toMove, .white)
    }

    func testStubRecognizerReturnsEmptyBoard() async throws {
        // A 1x1 opaque CGImage is enough to exercise the stub's contract.
        let ctx = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let image = ctx.makeImage()!
        let result = try await StubBoardRecognizer().recognize(image: image, boardSize: 19)
        XCTAssertEqual(result.size, 19)
        XCTAssertEqual(result.blackCount, 0)
        XCTAssertEqual(result.whiteCount, 0)
    }
}
