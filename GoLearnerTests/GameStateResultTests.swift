//
//  GameStateResultTests.swift
//  GoLearnerTests
//
//  Record-only GameState behavior that needs no engine (GameState suppresses
//  engine launch under XCTest, so these run purely through GoReplay):
//   • applyGenMove decodes a GTP genmove reply — a vertex, "pass", "resign",
//     or garbage — into the right record + game-over state.
//   • a resignation ends the game with the correct winner and a valid SGF
//     RE[...] code, distinct from the humanized status text.
//   • the White-perspective → to-move winrate flip (WinProb) is symmetric.
//

import XCTest
@testable import GoLearner

@MainActor
final class GameStateResultTests: XCTestCase {

    func testGenMoveVertexAppendsMoveAndFlipsSide() {
        let game = GameState()
        game.applyGenMove(vertex: "Q16", for: .black)
        XCTAssertEqual(game.totalMoves, 1)
        XCTAssertEqual(game.sideToMove, .white)
        XCTAssertFalse(game.gameOver)
        XCTAssertNil(game.resignedBy)
    }

    func testGenMoveResignEndsGameWithoutAppendingAMove() {
        let game = GameState()
        game.applyGenMove(vertex: "Q16", for: .black)   // one real move on the board
        let before = game.totalMoves
        game.applyGenMove(vertex: "resign", for: .white)

        XCTAssertEqual(game.totalMoves, before, "resign must not append a move")
        XCTAssertTrue(game.gameOver)
        XCTAssertEqual(game.resignedBy, .white)
        XCTAssertEqual(game.gameResultText, "Black wins by resignation")
    }

    func testResignationExportsValidSGFResultCode() {
        let game = GameState()
        game.applyGenMove(vertex: "resign", for: .black)
        XCTAssertEqual(game.resignedBy, .black)
        XCTAssertEqual(game.gameResultText, "White wins by resignation")
        // Exported SGF must carry a real RE code, not the display string.
        let sgf = game.exportSGF()
        XCTAssertTrue(sgf.contains("RE[W+R]"), "expected RE[W+R] in: \(sgf)")
        XCTAssertFalse(sgf.contains("resignation"), "display text leaked into SGF")
    }

    func testTwoPassesEndTheGameByScore() {
        let game = GameState()
        game.applyGenMove(vertex: "pass", for: .black)
        XCTAssertFalse(game.gameOver, "one pass is not game over")
        game.applyGenMove(vertex: "pass", for: .white)
        XCTAssertTrue(game.gameOver, "two passes end the game")
        XCTAssertNil(game.resignedBy, "a passed-out game is not a resignation")
    }

    func testGarbageVertexDegradesToPass() {
        let game = GameState()
        // Row 99 is off a 19×19 board, so the vertex is unparseable.
        game.applyGenMove(vertex: "Z99", for: .black)
        XCTAssertEqual(game.totalMoves, 1)
        XCTAssertEqual(game.sideToMove, .white)
    }

    func testApplyGenMoveBumpsRecordVersionForAutosave() {
        let game = GameState()
        let v0 = game.recordVersion
        game.applyGenMove(vertex: "Q16", for: .black)
        XCTAssertGreaterThan(game.recordVersion, v0)
    }

    func testResignationResultNamesTheOpponent() {
        XCTAssertEqual(GameState.resignationResult(loser: .black), "White wins by resignation")
        XCTAssertEqual(GameState.resignationResult(loser: .white), "Black wins by resignation")
    }

    func testWinProbFromWhiteIsSymmetric() {
        // A 0.7 White winrate is 0.3 for Black to move, and Black's share is 0.3.
        let blackToMove = WinProb.fromWhite(0.7, blackToMove: true)
        XCTAssertEqual(blackToMove.toMove, 0.3, accuracy: 1e-6)
        XCTAssertEqual(blackToMove.black, 0.3, accuracy: 1e-6)
        // Same winrate with White to move: to-move is 0.7, Black's share 0.3.
        let whiteToMove = WinProb.fromWhite(0.7, blackToMove: false)
        XCTAssertEqual(whiteToMove.toMove, 0.7, accuracy: 1e-6)
        XCTAssertEqual(whiteToMove.black, 0.3, accuracy: 1e-6)
    }
}
