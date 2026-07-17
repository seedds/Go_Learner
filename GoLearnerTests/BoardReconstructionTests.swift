//
//  BoardReconstructionTests.swift
//  GoLearnerTests
//
//  Verifies that replaying an SGF through the bridge yields the correct final
//  position, including captures — the basis for the library thumbnails.
//

import XCTest

@MainActor
final class BoardReconstructionTests: XCTestCase {

    private func at(_ stones: [GoColor], _ x: Int, _ y: Int, size: Int) -> GoColor {
        stones[y * size + x]
    }

    func testPlacesStonesFromMainLine() {
        let game = SGFGame(boardSize: 19, komi: 7.5, moves: [
            .play(.black, 3, 3), .play(.white, 15, 15),
        ])
        let stones = BoardReconstruction.stones(from: game)
        XCTAssertEqual(stones.count, 19 * 19)
        XCTAssertEqual(at(stones, 3, 3, size: 19), .black)
        XCTAssertEqual(at(stones, 15, 15, size: 19), .white)
        XCTAssertEqual(at(stones, 0, 0, size: 19), .empty)
    }

    func testResolvesCaptures() {
        // White at the corner gets captured by Black surrounding it.
        let game = SGFGame(boardSize: 19, komi: 7.5, moves: [
            .play(.black, 1, 0), .play(.white, 0, 0), .play(.black, 0, 1),
        ])
        let stones = BoardReconstruction.stones(from: game)
        XCTAssertEqual(at(stones, 0, 0, size: 19), .empty, "captured corner should be empty")
        XCTAssertEqual(at(stones, 1, 0, size: 19), .black)
    }

    func testHandlesPassAndSmallBoard() {
        let game = SGFGame(boardSize: 9, komi: 7, moves: [
            .play(.black, 4, 4), .pass(.white), .play(.black, 2, 2),
        ])
        let stones = BoardReconstruction.stones(from: game)
        XCTAssertEqual(stones.count, 9 * 9)
        XCTAssertEqual(at(stones, 4, 4, size: 9), .black)
        XCTAssertEqual(at(stones, 2, 2, size: 9), .black)
    }

    func testPlacesHandicapSetupStones() {
        // 2-stone handicap, then White plays; setup stones must be on the board.
        let game = SGFGame(boardSize: 19, komi: 0.5, moves: [.play(.white, 9, 9)],
                           handicap: 2, setupBlack: [SGFPoint(x: 15, y: 3), SGFPoint(x: 3, y: 15)])
        let stones = BoardReconstruction.stones(from: game)
        XCTAssertEqual(at(stones, 15, 3, size: 19), .black)
        XCTAssertEqual(at(stones, 3, 15, size: 19), .black)
        XCTAssertEqual(at(stones, 9, 9, size: 19), .white)
    }

    func testHandicapSetupResolvesCaptures() {
        // A black handicap stone in the corner is captured after White surrounds
        // it, exercising real rules over the setup base.
        let game = SGFGame(boardSize: 19, komi: 0.5, moves: [
            .play(.white, 1, 0), .play(.black, 5, 5), .play(.white, 0, 1),
        ], handicap: 2, setupBlack: [SGFPoint(x: 0, y: 0), SGFPoint(x: 3, y: 15)])
        let stones = BoardReconstruction.stones(from: game)
        XCTAssertEqual(at(stones, 0, 0, size: 19), .empty, "surrounded handicap stone captured")
        XCTAssertEqual(at(stones, 3, 15, size: 19), .black, "other handicap stone remains")
    }
}
