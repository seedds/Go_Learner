//
//  MCTSTests.swift
//  GoLearnerTests
//
//  Exercises the PUCT search against the real bridge with a deterministic
//  fake evaluator (the Core ML model can't load in this hostless bundle).
//

import XCTest

/// Uniform-policy, always-balanced fake evaluator.
private struct FakeEvaluator: PositionEvaluator {
    func evaluate(spatial: [Float], global: [Float], legalMask: [Bool], blackToMove: Bool) async throws -> NNResult {
        let area = legalMask.count - 1
        let legalCount = legalMask.filter { $0 }.count
        let p = 1.0 / Float(max(legalCount, 1))
        var policy = [Float](repeating: 0, count: area)
        for pos in 0..<area where legalMask[pos] { policy[pos] = p }
        return NNResult(policy: policy,
                        passPolicy: legalMask[area] ? p : 0,
                        winProbToMove: 0.5,
                        noResultProb: 0,
                        whiteScoreMean: 0,
                        whiteLead: 0,
                        whiteOwnership: [Float](repeating: 0, count: area))
    }
}

/// Balanced value, but almost all policy mass on the pass move so search
/// explores passing immediately. Used to check terminal handling without
/// needing hundreds of playouts to discover pass among a uniform prior.
private struct PassFavoringEvaluator: PositionEvaluator {
    func evaluate(spatial: [Float], global: [Float], legalMask: [Bool], blackToMove: Bool) async throws -> NNResult {
        let area = legalMask.count - 1
        let boardShare: Float = 0.1
        let legalBoard = (0..<area).filter { legalMask[$0] }.count
        let per = legalBoard > 0 ? boardShare / Float(legalBoard) : 0
        var policy = [Float](repeating: 0, count: area)
        for pos in 0..<area where legalMask[pos] { policy[pos] = per }
        return NNResult(policy: policy,
                        passPolicy: 0.9,
                        winProbToMove: 0.5,
                        noResultProb: 0,
                        whiteScoreMean: 0,
                        whiteLead: 0,
                        whiteOwnership: [Float](repeating: 0, count: area))
    }
}

final class MCTSTests: XCTestCase {

    @MainActor
    func testSearchRunsRequestedPlayouts() async {
        let bridge = GoBridge(boardSize: 9, komi: 7.5)
        let mcts = MCTS(boardSize: 9, evaluator: FakeEvaluator())
        let result = await mcts.search(rootBridge: bridge, playouts: 30) { true }
        XCTAssertNotNil(result)
        XCTAssertEqual(result!.playouts, 30)
        // Original game untouched by the search.
        XCTAssertEqual(bridge.moveCount, 0)
        XCTAssertEqual(bridge.sideToMove, .black)
    }

    @MainActor
    func testPolicyIsVisitFractionOverLegalMoves() async {
        let bridge = GoBridge(boardSize: 9, komi: 7.5)
        let mcts = MCTS(boardSize: 9, evaluator: FakeEvaluator())
        let result = await mcts.search(rootBridge: bridge, playouts: 40) { true }!
        let total = result.policy.reduce(0, +) + result.passPolicy
        XCTAssertEqual(total, 1.0, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(result.policy.min() ?? 0, 0)
    }

    @MainActor
    func testStopsWhenShouldContinueFalse() async {
        let bridge = GoBridge(boardSize: 9, komi: 7.5)
        let mcts = MCTS(boardSize: 9, evaluator: FakeEvaluator())
        var calls = 0
        let result = await mcts.search(rootBridge: bridge, playouts: 100) {
            calls += 1
            return calls <= 5
        }
        XCTAssertNotNil(result)
        XCTAssertLessThan(result!.playouts, 100)
    }

    @MainActor
    func testTerminalDoublePassUsesRealScore() async {
        // Position: game one pass from ending. Root side = White; if White
        // passes, game ends with White winning by komi on an empty board.
        // The evaluator is value-balanced (0.5) everywhere, so only the REAL
        // terminal score (White win → Black value 0) can pull the root below
        // 0.5 and make pass the most-visited move. A pass-favoring prior lets
        // the search reach the terminal node in a few playouts.
        let bridge = GoBridge(boardSize: 9, komi: 7.5)
        bridge.pass(for: .black)
        let mcts = MCTS(boardSize: 9, evaluator: PassFavoringEvaluator())
        let result = await mcts.search(rootBridge: bridge, playouts: 40) { true }!
        XCTAssertNil(result.bestMove, "White should pass to win by komi")
        XCTAssertLessThan(result.blackWinProb, 0.5)
    }
}
