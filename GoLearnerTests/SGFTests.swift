//
//  SGFTests.swift
//  GoLearnerTests
//
//  Round-trip and parsing tests for the SGF codec. Pure value-type tests
//  (no bridge / no CoreML) so they run in the standalone logic bundle.
//

import XCTest
@testable import GoLearner

final class SGFTests: XCTestCase {

    func testSerializeBasicHeaderAndMoves() {
        let game = SGFGame(boardSize: 19, komi: 7.5, moves: [
            .play(.black, 3, 3), .play(.white, 15, 15), .pass(.black),
        ])
        let sgf = SGF.serialize(game)
        XCTAssertTrue(sgf.hasPrefix("(;"))
        XCTAssertTrue(sgf.hasSuffix(")"))
        XCTAssertTrue(sgf.contains("SZ[19]"))
        XCTAssertTrue(sgf.contains("KM[7.5]"))
        XCTAssertTrue(sgf.contains(";B[dd]"))   // (3,3) -> d,d
        XCTAssertTrue(sgf.contains(";W[pp]"))   // (15,15) -> p,p
        XCTAssertTrue(sgf.contains(";B[]"))     // pass
    }

    func testWholeKomiSerializesAsInteger() {
        let sgf = SGF.serialize(SGFGame(boardSize: 9, komi: 7, moves: []))
        XCTAssertTrue(sgf.contains("KM[7]"))
        XCTAssertTrue(sgf.contains("SZ[9]"))
    }

    func testParseMovesAndMetadata() throws {
        let text = "(;GM[1]FF[4]SZ[19]KM[6.5]PB[Alice]PW[Bob]RE[B+R];B[dd];W[pp];B[])"
        let game = try SGF.parse(text)
        XCTAssertEqual(game.boardSize, 19)
        XCTAssertEqual(game.komi, 6.5)
        XCTAssertEqual(game.blackName, "Alice")
        XCTAssertEqual(game.whiteName, "Bob")
        XCTAssertEqual(game.result, "B+R")
        XCTAssertEqual(game.moves, [.play(.black, 3, 3), .play(.white, 15, 15), .pass(.black)])
    }

    func testRoundTripPreservesMoves() throws {
        let original = SGFGame(boardSize: 13, komi: 7.5, moves: [
            .play(.black, 2, 2), .play(.white, 10, 10),
            .play(.black, 6, 6), .pass(.white),
        ])
        let decoded = try SGF.parse(SGF.serialize(original))
        XCTAssertEqual(decoded.boardSize, 13)
        XCTAssertEqual(decoded.komi, 7.5)
        XCTAssertEqual(decoded.moves, original.moves)
    }

    func testLegacyTTPassOnSmallBoard() throws {
        let game = try SGF.parse("(;SZ[19];B[tt];W[dd])")
        XCTAssertEqual(game.moves.first, .pass(.black))
        XCTAssertEqual(game.moves.last, .play(.white, 3, 3))
    }

    func testParseIgnoresVariationsAfterMainLine() throws {
        // A branch starts with '(' after the main line; import should stop there.
        let game = try SGF.parse("(;SZ[19];B[dd];W[pp](;B[qq])(;B[cc]))")
        XCTAssertEqual(game.moves, [.play(.black, 3, 3), .play(.white, 15, 15)])
    }

    func testParseNoGameTreeThrows() {
        XCTAssertThrowsError(try SGF.parse("not an sgf")) { error in
            XCTAssertEqual(error as? SGFError, .noGameTree)
        }
    }

    func testEscapedBracketInName() throws {
        let game = try SGF.parse("(;SZ[19]PB[A\\]B];B[dd])")
        XCTAssertEqual(game.blackName, "A]B")
    }

    // MARK: Handicap

    func testSerializeHandicapAndSetupStones() {
        let game = SGFGame(boardSize: 19, komi: 0.5, moves: [.play(.white, 9, 9)],
                           handicap: 2, setupBlack: [SGFPoint(x: 15, y: 3), SGFPoint(x: 3, y: 15)])
        let sgf = SGF.serialize(game)
        XCTAssertTrue(sgf.contains("HA[2]"))
        XCTAssertTrue(sgf.contains("AB[pd][dp]"))  // (15,3)->pd, (3,15)->dp
        XCTAssertTrue(sgf.contains(";W[jj]"))      // (9,9) -> j,j, White first
    }

    func testParseHandicapAndSetupStones() throws {
        let text = "(;GM[1]SZ[19]HA[3]KM[0.5]AB[pd][dp][pp];W[jj];B[cc])"
        let game = try SGF.parse(text)
        XCTAssertEqual(game.handicap, 3)
        XCTAssertEqual(game.setupBlack,
                       [SGFPoint(x: 15, y: 3), SGFPoint(x: 3, y: 15), SGFPoint(x: 15, y: 15)])
        XCTAssertEqual(game.moves, [.play(.white, 9, 9), .play(.black, 2, 2)])
    }

    func testRoundTripPreservesHandicap() throws {
        let original = SGFGame(boardSize: 19, komi: 0.5,
                               moves: [.play(.white, 9, 9), .play(.black, 2, 2)],
                               handicap: 4,
                               setupBlack: HandicapPoints.fixed(count: 4, boardSize: 19))
        let decoded = try SGF.parse(SGF.serialize(original))
        XCTAssertEqual(decoded.handicap, 4)
        XCTAssertEqual(decoded.setupBlack, original.setupBlack)
        XCTAssertEqual(decoded.moves, original.moves)
    }

    func testEvenGameHasNoHandicapTags() {
        let sgf = SGF.serialize(SGFGame(boardSize: 19, komi: 7.5, moves: [.play(.black, 3, 3)]))
        XCTAssertFalse(sgf.contains("HA["))
        XCTAssertFalse(sgf.contains("AB["))
    }

    // MARK: Setup positions (edited / photo-imported)

    func testSerializeSetupWhiteAndPlayerToMove() {
        // A White-to-play puzzle: black + white setup stones, explicit PL, no HA.
        let game = SGFGame(boardSize: 19, komi: 7, moves: [],
                           setupBlack: [SGFPoint(x: 3, y: 3)],
                           setupWhite: [SGFPoint(x: 15, y: 15), SGFPoint(x: 2, y: 2)],
                           playerToMove: .white)
        let sgf = SGF.serialize(game)
        XCTAssertTrue(sgf.contains("AB[dd]"))
        XCTAssertTrue(sgf.contains("AW[pp][cc]"))
        XCTAssertTrue(sgf.contains("PL[W]"))
        XCTAssertFalse(sgf.contains("HA["), "an edited position is not a handicap")
    }

    func testParseSetupWhiteAndPlayerToMove() throws {
        let text = "(;GM[1]SZ[19]KM[7]AB[dd]AW[pp][cc]PL[W])"
        let game = try SGF.parse(text)
        XCTAssertEqual(game.setupBlack, [SGFPoint(x: 3, y: 3)])
        XCTAssertEqual(game.setupWhite, [SGFPoint(x: 15, y: 15), SGFPoint(x: 2, y: 2)])
        XCTAssertEqual(game.playerToMove, .white)
    }

    func testRoundTripPreservesSetupAndPlayerToMove() throws {
        let original = SGFGame(boardSize: 13, komi: 7,
                               moves: [.play(.white, 6, 6)],
                               setupBlack: [SGFPoint(x: 2, y: 2), SGFPoint(x: 10, y: 3)],
                               setupWhite: [SGFPoint(x: 3, y: 10)],
                               playerToMove: .white)
        let decoded = try SGF.parse(SGF.serialize(original))
        XCTAssertEqual(decoded.setupBlack, original.setupBlack)
        XCTAssertEqual(decoded.setupWhite, original.setupWhite)
        XCTAssertEqual(decoded.playerToMove, .white)
        XCTAssertEqual(decoded.moves, original.moves)
    }

    func testMissingPlayerToMoveParsesNil() throws {
        // A plain even game has no PL tag; the caller derives the side to move.
        let game = try SGF.parse("(;SZ[19];B[dd])")
        XCTAssertNil(game.playerToMove)
        XCTAssertTrue(game.setupWhite.isEmpty)
    }

    func testRoundTripPreservesSubNineteenHandicap() throws {
        // A 9×9 handicap game must persist its sub-19 setup stones so reloads
        // keep the engine + display in sync (see HandicapPoints).
        let stones = HandicapPoints.fixed(count: 4, boardSize: 9)
        let original = SGFGame(boardSize: 9, komi: 0.5,
                               moves: [.play(.white, 4, 4)],
                               handicap: 4, setupBlack: stones)
        let decoded = try SGF.parse(SGF.serialize(original))
        XCTAssertEqual(decoded.boardSize, 9)
        XCTAssertEqual(decoded.handicap, 4)
        XCTAssertEqual(decoded.setupBlack, stones)
        XCTAssertEqual(decoded.moves, original.moves)
    }
}
