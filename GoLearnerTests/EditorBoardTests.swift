//
//  EditorBoardTests.swift
//  GoLearnerTests
//
//  The pure editor model: paint/erase/clear, seeding from a setup or grid, and
//  the round-trip to a SetupPosition (row-major point extraction + side to move).
//

import XCTest
@testable import GoLearner

final class EditorBoardTests: XCTestCase {

    func testPaintAndErase() {
        var b = EditorBoard(size: 9)
        b.apply(.black, x: 2, y: 3)
        b.apply(.white, x: 4, y: 4)
        XCTAssertEqual(b.color(x: 2, y: 3), .black)
        XCTAssertEqual(b.color(x: 4, y: 4), .white)
        XCTAssertEqual(b.blackCount, 1)
        XCTAssertEqual(b.whiteCount, 1)

        b.apply(.erase, x: 2, y: 3)
        XCTAssertEqual(b.color(x: 2, y: 3), .empty)
        XCTAssertEqual(b.blackCount, 0)
    }

    func testPaintIsIdempotentNotToggling() {
        var b = EditorBoard(size: 9)
        b.apply(.black, x: 0, y: 0)
        b.apply(.black, x: 0, y: 0)   // painting again keeps it black (no cycle)
        XCTAssertEqual(b.color(x: 0, y: 0), .black)
    }

    func testOutOfBoundsIgnored() {
        var b = EditorBoard(size: 9)
        b.apply(.black, x: -1, y: 0)
        b.apply(.black, x: 9, y: 9)
        XCTAssertTrue(b.isEmpty)
    }

    func testClearKeepsToMove() {
        var b = EditorBoard(size: 9, toMove: .white)
        b.apply(.black, x: 1, y: 1)
        b.clear()
        XCTAssertTrue(b.isEmpty)
        XCTAssertEqual(b.toMove, .white)
    }

    func testToSetupExtractsBothColorsAndTurn() {
        var b = EditorBoard(size: 19, toMove: .white)
        b.apply(.black, x: 3, y: 3)
        b.apply(.white, x: 15, y: 15)
        let setup = b.toSetup()
        XCTAssertEqual(setup.black, [SGFPoint(x: 3, y: 3)])
        XCTAssertEqual(setup.white, [SGFPoint(x: 15, y: 15)])
        XCTAssertEqual(setup.toMove, .white)
    }

    func testSeedFromSetupRoundTrips() {
        let setup = SetupPosition(black: [SGFPoint(x: 2, y: 2), SGFPoint(x: 5, y: 6)],
                                  white: [SGFPoint(x: 10, y: 10)],
                                  toMove: .white)
        let b = EditorBoard(setup: setup, size: 13)
        XCTAssertEqual(b.color(x: 2, y: 2), .black)
        XCTAssertEqual(b.color(x: 5, y: 6), .black)
        XCTAssertEqual(b.color(x: 10, y: 10), .white)
        // Round-trip back to a setup preserves stones + turn.
        XCTAssertEqual(b.toSetup(), setup)
    }

    func testSeedFromGridMatchingSize() {
        var cells = [GoColor](repeating: .empty, count: 9 * 9)
        cells[0] = .black
        cells[9 * 9 - 1] = .white
        let b = EditorBoard(cells: cells, size: 9, toMove: .black)
        XCTAssertEqual(b.color(x: 0, y: 0), .black)
        XCTAssertEqual(b.color(x: 8, y: 8), .white)
    }

    func testSeedFromGridWrongSizeIsEmpty() {
        let b = EditorBoard(cells: [.black, .white], size: 9, toMove: .black)
        XCTAssertTrue(b.isEmpty)
    }
}
