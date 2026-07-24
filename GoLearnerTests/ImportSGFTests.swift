//
//  ImportSGFTests.swift
//  GoLearnerTests
//
//  GameState.importSGF gating (engine-free; GameState suppresses engine launch
//  under XCTest). An SGF whose setup stones aren't physically placeable (a
//  zero-liberty group) must be REJECTED without mutating the current game —
//  otherwise the engine's loadsgf would reject it and the display would drift
//  from the engine (AGENTS.md setup trap). A valid file imports normally.
//

import XCTest
@testable import GoLearner

@MainActor
final class ImportSGFTests: XCTestCase {

    func testRejectsUnparseableSGFAndKeepsCurrentGame() {
        let game = GameState()
        game.applyGenMove(vertex: "Q16", for: .black)   // a move worth protecting
        let before = game.totalMoves
        XCTAssertFalse(game.importSGF("not an sgf at all"))
        XCTAssertEqual(game.totalMoves, before, "a bad parse must not disturb the game")
    }

    func testRejectsZeroLibertySetupWithoutMutating() {
        let game = GameState()
        game.applyGenMove(vertex: "Q16", for: .black)
        let beforeMoves = game.totalMoves
        let beforeSize = game.boardSize

        // A white stone fully surrounded by black on all four sides at (1,1) has
        // no liberties — the engine's setStonesFailIfNoLibs (and thus loadsgf)
        // rejects it. AB = black ring, AW = the trapped white stone.
        //   (1,0)=ba (0,1)=ab (2,1)=cb (1,2)=bc black ; (1,1)=bb white
        let deadWhite = "(;GM[1]FF[4]SZ[19]RU[Chinese]KM[7]"
            + "AB[ba][ab][cb][bc]AW[bb])"
        XCTAssertFalse(game.importSGF(deadWhite),
                       "a zero-liberty setup must be rejected")
        XCTAssertEqual(game.totalMoves, beforeMoves, "state must be untouched on reject")
        XCTAssertEqual(game.boardSize, beforeSize)
    }

    func testImportsValidSetupSGF() {
        let game = GameState()
        // Two black + one white stone, all with liberties, White to play.
        let ok = "(;GM[1]FF[4]SZ[19]RU[Chinese]KM[7]PL[W]AB[dd][dp]AW[pp])"
        XCTAssertTrue(game.importSGF(ok))
        XCTAssertEqual(game.setup.black.count, 2)
        XCTAssertEqual(game.setup.white.count, 1)
        XCTAssertEqual(game.sideToMove, .white, "PL[W] should make White the side to move")
    }

    func testImportAdoptsBoardSize() {
        let game = GameState()              // defaults to 19
        let ok = "(;GM[1]FF[4]SZ[9]RU[Chinese]KM[7];B[cc];W[gg])"
        XCTAssertTrue(game.importSGF(ok))
        XCTAssertEqual(game.boardSize, 9)
        XCTAssertEqual(game.totalMoves, 2)
    }
}
