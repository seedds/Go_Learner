//
//  SetupPositionTests.swift
//  GoLearnerTests
//
//  The setup-base value type: handicap construction, the SGF side-to-move
//  derivation, and the SGF-shaping helpers (HA vs PL) that keep normal games
//  tag-free while edited puzzles carry their explicit turn. Pure value tests.
//

import XCTest
@testable import GoLearner

final class SetupPositionTests: XCTestCase {

    func testEmptyBaseIsBlackToMove() {
        XCTAssertTrue(SetupPosition.empty.isEmpty)
        XCTAssertEqual(SetupPosition.empty.toMove, .black)
        XCTAssertFalse(SetupPosition.empty.needsExplicitPlayerToMove)
    }

    func testHandicapIsBlackStonesWhiteToMove() {
        let s = SetupPosition.handicap(count: 4, boardSize: 19)
        XCTAssertEqual(s.black.count, 4)
        XCTAssertTrue(s.white.isEmpty)
        XCTAssertEqual(s.toMove, .white)
        XCTAssertTrue(s.isHandicap)
        XCTAssertEqual(s.handicapCount, 4)
        // A handicap's turn is the derived default, so no explicit PL is needed.
        XCTAssertFalse(s.needsExplicitPlayerToMove)
    }

    func testUnsupportedHandicapCollapsesToEven() {
        let s = SetupPosition.handicap(count: 0, boardSize: 19)
        XCTAssertTrue(s.isEmpty)
        XCTAssertEqual(s.toMove, .black)
    }

    func testDerivedToMove() {
        // Black-only setup → White opens (handicap-like).
        XCTAssertEqual(SetupPosition(black: [SGFPoint(x: 3, y: 3)]).derivedToMove, .white)
        // Any white stones present → Black opens by default.
        XCTAssertEqual(SetupPosition(white: [SGFPoint(x: 3, y: 3)]).derivedToMove, .black)
        XCTAssertEqual(SetupPosition(black: [SGFPoint(x: 0, y: 0)],
                                     white: [SGFPoint(x: 1, y: 1)]).derivedToMove, .black)
    }

    func testNeedsExplicitPlayerToMoveWhenOverridingDerived() {
        // Black-only setup but Black to move: differs from the derived White.
        let s = SetupPosition(black: [SGFPoint(x: 3, y: 3)], toMove: .black)
        XCTAssertTrue(s.needsExplicitPlayerToMove)
        XCTAssertFalse(s.isHandicap, "Black-to-move black stones aren't a handicap")
        XCTAssertEqual(s.handicapCount, 0)
    }

    func testInitFromSGFUsesExplicitPLWhenPresent() {
        let game = SGFGame(boardSize: 19, komi: 7, moves: [],
                           setupBlack: [SGFPoint(x: 3, y: 3)],
                           setupWhite: [SGFPoint(x: 15, y: 15)],
                           playerToMove: .white)
        let s = SetupPosition(sgf: game)
        XCTAssertEqual(s.toMove, .white)
        XCTAssertEqual(s.black, game.setupBlack)
        XCTAssertEqual(s.white, game.setupWhite)
    }

    func testInitFromSGFDerivesWhenPLMissing() {
        // Handicap-shaped SGF without PL → White opens.
        let handi = SGFGame(boardSize: 19, komi: 0.5, moves: [],
                            handicap: 2, setupBlack: [SGFPoint(x: 3, y: 3), SGFPoint(x: 15, y: 15)])
        XCTAssertEqual(SetupPosition(sgf: handi).toMove, .white)
        // Even game without PL → Black opens.
        let even = SGFGame(boardSize: 19, komi: 7, moves: [.play(.black, 3, 3)])
        XCTAssertEqual(SetupPosition(sgf: even).toMove, .black)
    }
}
