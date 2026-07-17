//
//  GoBridgeTests.swift
//  GoLearnerTests
//
//  Verifies the correctness-critical C++ bridge path: legality, turn order,
//  capture, undo, and NN feature-buffer generation. These mirror the host
//  harness that validated the vendored KataGo subset.
//

import XCTest
// This is a standalone logic bundle that compiles the ObjC++ GoBridge and the
// vendored KataGo C++ subset itself (see project.yml), so the bridge types are
// available directly through the bridging header — no `import GoLearner` needed,
// which also avoids duplicating the GoBridge ObjC class.

final class GoBridgeTests: XCTestCase {

    func makeBridge(_ size: Int32 = 19) -> GoBridge {
        GoBridge(boardSize: size, komi: 7.5)
    }

    func testFreshGameState() {
        let b = makeBridge()
        XCTAssertEqual(b.boardSize, 19)
        XCTAssertEqual(b.sideToMove, .black)
        XCTAssertEqual(b.moveCount, 0)
        XCTAssertEqual(b.stoneColor(atX: 0, y: 0), .empty)
    }

    func testTurnOrderEnforced() {
        let b = makeBridge()
        // White cannot move first.
        XCTAssertFalse(b.isLegalX(3, y: 3, color: .white))
        XCTAssertTrue(b.isLegalX(3, y: 3, color: .black))
        XCTAssertTrue(b.playX(3, y: 3, color: .black))
        XCTAssertEqual(b.sideToMove, .white)
        // Now Black cannot move.
        XCTAssertFalse(b.playX(4, y: 4, color: .black))
        XCTAssertTrue(b.playX(4, y: 4, color: .white))
    }

    func testCapture() {
        let b = makeBridge()
        // Black(1,0), White(0,0), Black(0,1) captures the white corner stone.
        XCTAssertTrue(b.playX(1, y: 0, color: .black))
        XCTAssertTrue(b.playX(0, y: 0, color: .white))
        XCTAssertEqual(b.stoneColor(atX: 0, y: 0), .white)
        XCTAssertTrue(b.playX(0, y: 1, color: .black))
        XCTAssertEqual(b.stoneColor(atX: 0, y: 0), .empty, "corner should be captured")
        XCTAssertEqual(b.blackCaptures, 1, "Black should have 1 prisoner")
    }

    func testUndo() {
        let b = makeBridge()
        XCTAssertTrue(b.playX(3, y: 3, color: .black))
        XCTAssertTrue(b.playX(15, y: 15, color: .white))
        XCTAssertEqual(b.moveCount, 2)
        XCTAssertTrue(b.undo())
        XCTAssertEqual(b.moveCount, 1)
        XCTAssertEqual(b.stoneColor(atX: 15, y: 15), .empty)
        XCTAssertEqual(b.sideToMove, .white)
        XCTAssertTrue(b.undo())
        XCTAssertEqual(b.moveCount, 0)
        XCTAssertEqual(b.stoneColor(atX: 3, y: 3), .empty)
        XCTAssertFalse(b.undo(), "nothing left to undo")
    }

    func testFeatureShapesAndOnBoardMask() {
        let b = makeBridge()
        let size = 19
        let area = size * size
        var spatial = [Float](repeating: -1, count: Int(GoBridgeNumSpatialFeatures) * area)
        var global = [Float](repeating: -1, count: Int(GoBridgeNumGlobalFeatures))
        spatial.withUnsafeMutableBufferPointer { sp in
            global.withUnsafeMutableBufferPointer { gp in
                b.fillSpatial(sp.baseAddress!, global: gp.baseAddress!)
            }
        }
        XCTAssertEqual(Int(GoBridgeNumSpatialFeatures), 22)
        XCTAssertEqual(Int(GoBridgeNumGlobalFeatures), 19)
        // Channel 0 is the on-board mask; on a full 19x19 it sums to 361.
        let ch0 = spatial[0..<area].reduce(0, +)
        XCTAssertEqual(ch0, 361, accuracy: 0.001)
    }

    func testDoublePassEndsAndScoresGame() {
        let b = makeBridge()
        XCTAssertFalse(b.gameFinished)
        b.pass(for: .black)
        XCTAssertFalse(b.gameFinished)
        b.pass(for: .white)
        XCTAssertTrue(b.gameFinished)
        XCTAssertFalse(b.isNoResult)
        // Empty board, area scoring: White wins by komi.
        XCTAssertEqual(b.winner, .white)
        XCTAssertEqual(b.finalWhiteMinusBlackScore, 7.5, accuracy: 0.001)
    }

    func testUndoRevivesFinishedGame() {
        let b = makeBridge()
        b.pass(for: .black)
        b.pass(for: .white)
        XCTAssertTrue(b.gameFinished)
        XCTAssertTrue(b.undo())
        XCTAssertFalse(b.gameFinished)
        XCTAssertEqual(b.sideToMove, .white)
    }

    func testCloneIsIndependent() {
        let b = makeBridge()
        XCTAssertTrue(b.playX(3, y: 3, color: .black))
        let c = b.clone()
        XCTAssertTrue(c.playX(15, y: 15, color: .white))
        // Clone advanced; original untouched.
        XCTAssertEqual(c.moveCount, 2)
        XCTAssertEqual(b.moveCount, 1)
        XCTAssertEqual(b.stoneColor(atX: 15, y: 15), .empty)
        XCTAssertEqual(c.stoneColor(atX: 3, y: 3), .black)
    }

    func testDefaultRulesAreTrompTaylorish() {
        let b = makeBridge()
        XCTAssertEqual(b.koRule, 1)       // KO_POSITIONAL
        XCTAssertEqual(b.scoringRule, 0)  // SCORING_AREA
    }

    func testResetWithExplicitRules() {
        let b = makeBridge()
        _ = b.playX(3, y: 3, color: .black)
        b.reset(withBoardSize: 19, komi: 6.5, koRule: 0, scoringRule: 1) // simple / territory
        XCTAssertEqual(b.koRule, 0)
        XCTAssertEqual(b.scoringRule, 1)
        XCTAssertEqual(b.komi, 6.5, accuracy: 0.001)
        XCTAssertEqual(b.moveCount, 0, "reset clears the position")
        XCTAssertEqual(b.stoneColor(atX: 3, y: 3), .empty)
        // Turn order and play still work under the new rules.
        XCTAssertTrue(b.playX(3, y: 3, color: .black))
    }

    func testResetKeepsRulesWhenUnspecified() {
        let b = makeBridge()
        b.reset(withBoardSize: 19, komi: 5.5, koRule: 2, scoringRule: 1)
        b.reset(withBoardSize: 19, komi: 0.5) // rules-preserving overload
        XCTAssertEqual(b.koRule, 2)
        XCTAssertEqual(b.scoringRule, 1)
        XCTAssertEqual(b.komi, 0.5, accuracy: 0.001)
    }

    func testSnapshotAtPlyRewindsWithoutTouchingOriginal() {
        let b = makeBridge()
        XCTAssertTrue(b.playX(3, y: 3, color: .black))
        XCTAssertTrue(b.playX(15, y: 15, color: .white))
        XCTAssertTrue(b.playX(3, y: 15, color: .black))
        XCTAssertEqual(b.moveCount, 3)

        // Rewind to just after Black's first move.
        let s = b.snapshot(atPly: 1)
        XCTAssertEqual(s.moveCount, 1)
        XCTAssertEqual(s.stoneColor(atX: 3, y: 3), .black)
        XCTAssertEqual(s.stoneColor(atX: 15, y: 15), .empty)
        XCTAssertEqual(s.sideToMove, .white)

        // Original is untouched.
        XCTAssertEqual(b.moveCount, 3)
        XCTAssertEqual(b.stoneColor(atX: 3, y: 15), .black)
    }

    func testSnapshotAtPlyClampsAndBounds() {
        let b = makeBridge()
        _ = b.playX(3, y: 3, color: .black)
        _ = b.playX(15, y: 15, color: .white)

        // ply 0 => empty board.
        let start = b.snapshot(atPly: 0)
        XCTAssertEqual(start.moveCount, 0)
        XCTAssertEqual(start.stoneColor(atX: 3, y: 3), .empty)

        // Over-large ply clamps to the current tip.
        let end = b.snapshot(atPly: 99)
        XCTAssertEqual(end.moveCount, 2)
        XCTAssertEqual(end.stoneColor(atX: 15, y: 15), .white)
    }

    // MARK: Handicap

    /// Place `points` (x,y) as black handicap stones via the C primitive.
    private func setupHandicap(_ b: GoBridge, _ points: [(Int32, Int32)]) {
        let xs = points.map { $0.0 }
        let ys = points.map { $0.1 }
        xs.withUnsafeBufferPointer { xp in
            ys.withUnsafeBufferPointer { yp in
                b.setupHandicap(xs: xp.baseAddress!, ys: yp.baseAddress!, count: Int32(points.count))
            }
        }
    }

    func testHandicapPlacesStonesAndWhiteMovesFirst() {
        let b = makeBridge()
        setupHandicap(b, [(15, 3), (3, 15)])
        XCTAssertEqual(b.stoneColor(atX: 15, y: 3), .black)
        XCTAssertEqual(b.stoneColor(atX: 3, y: 15), .black)
        XCTAssertEqual(b.sideToMove, .white, "White opens a handicap game")
        XCTAssertEqual(b.moveCount, 0, "setup stones are not counted moves")
        // Black cannot move first; White can.
        XCTAssertFalse(b.isLegalX(9, y: 9, color: .black))
        XCTAssertTrue(b.playX(9, y: 9, color: .white))
    }

    func testHandicapIsTheReplayBaseForUndo() {
        let b = makeBridge()
        setupHandicap(b, [(15, 3), (3, 15), (15, 15)])
        XCTAssertTrue(b.playX(9, y: 9, color: .white))
        XCTAssertTrue(b.playX(2, y: 2, color: .black))
        XCTAssertEqual(b.moveCount, 2)

        XCTAssertTrue(b.undo())
        XCTAssertTrue(b.undo())
        XCTAssertEqual(b.moveCount, 0)
        // Undo stops at the handicap base: stones remain, White to move.
        XCTAssertFalse(b.undo(), "cannot undo below the handicap setup")
        XCTAssertEqual(b.stoneColor(atX: 15, y: 3), .black)
        XCTAssertEqual(b.stoneColor(atX: 3, y: 15), .black)
        XCTAssertEqual(b.stoneColor(atX: 15, y: 15), .black)
        XCTAssertEqual(b.sideToMove, .white)
    }

    func testHandicapSnapshotAtPlyZeroIsTheSetup() {
        let b = makeBridge()
        setupHandicap(b, [(15, 3), (3, 15)])
        _ = b.playX(9, y: 9, color: .white)

        let base = b.snapshot(atPly: 0)
        XCTAssertEqual(base.moveCount, 0)
        XCTAssertEqual(base.stoneColor(atX: 15, y: 3), .black, "handicap stone present at base")
        XCTAssertEqual(base.stoneColor(atX: 9, y: 9), .empty, "move not yet applied")
        XCTAssertEqual(base.sideToMove, .white)

        // Original untouched.
        XCTAssertEqual(b.stoneColor(atX: 9, y: 9), .white)
    }

    func testHandicapClonePreservesBase() {
        let b = makeBridge()
        setupHandicap(b, [(15, 3), (3, 15)])
        _ = b.playX(9, y: 9, color: .white)
        let c = b.clone()
        // Clone can undo back to — but not below — the handicap base.
        XCTAssertTrue(c.undo())
        XCTAssertEqual(c.moveCount, 0)
        XCTAssertFalse(c.undo())
        XCTAssertEqual(c.stoneColor(atX: 15, y: 3), .black)
        XCTAssertEqual(c.sideToMove, .white)
    }

    func testLastMoveTracking() {
        let b = makeBridge()
        var lx: Int32 = -9, ly: Int32 = -9
        b.lastMoveX(&lx, y: &ly)
        XCTAssertEqual(lx, -1)
        XCTAssertEqual(ly, -1)
        _ = b.playX(2, y: 5, color: .black)
        b.lastMoveX(&lx, y: &ly)
        XCTAssertEqual(lx, 2)
        XCTAssertEqual(ly, 5)
        b.pass(for: .white) // pass shouldn't change last *stone* move
        b.lastMoveX(&lx, y: &ly)
        XCTAssertEqual(lx, 2)
        XCTAssertEqual(ly, 5)
    }
}
