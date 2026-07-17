//
//  GameState.swift
//  GoLearner
//
//  The main-actor observable model. Owns the single-threaded C++ GoBridge and
//  drives the async GoEngine (Core ML). Holds all state the SwiftUI views read.
//

import SwiftUI
import Observation
import os.log

enum PlayerKind: String, CaseIterable {
    case human = "Human"
    case ai = "AI"
}

@MainActor
@Observable
final class GameState {
    // MARK: Configuration
    let boardSize: Int
    let komi: Float

    // MARK: Board state (mirrors the C++ bridge for rendering)
    /// Flat board colors, index = y*boardSize + x.
    private(set) var stones: [GoColor]
    private(set) var lastMove: (x: Int, y: Int)?
    private(set) var blackCaptures: Int = 0
    private(set) var whiteCaptures: Int = 0
    private(set) var sideToMove: GoColor = .black
    private(set) var moveCount: Int = 0
    private(set) var gameOver: Bool = false
    private(set) var gameResultText: String? = nil

    // MARK: Player assignment
    var blackPlayer: PlayerKind = .human
    var whitePlayer: PlayerKind = .ai

    // MARK: Analysis
    var analysisEnabled: Bool = false
    private(set) var analysis: NNResult?
    private(set) var thinking: Bool = false
    private(set) var statusMessage: String = "Loading network…"
    private(set) var modelReady: Bool = false

    private let bridge: GoBridge
    private let engine: GoEngine
    private var mcts: MCTS? = nil
    private var analysisTask: Task<Void, Never>? = nil
    /// Monotonic token so stale async results are ignored after new moves.
    private var generation: Int = 0

    #if targetEnvironment(simulator)
    private let aiPlayouts = 24        // Core ML runs on CPU in the sim; keep it snappy
    private let analysisPlayouts = 12
    #else
    private let aiPlayouts = 100
    private let analysisPlayouts = 48
    #endif

    init(boardSize: Int = 19, komi: Float = 7.5) {
        self.boardSize = boardSize
        self.komi = komi
        self.bridge = GoBridge(boardSize: Int32(boardSize), komi: komi)
        self.engine = GoEngine(size: boardSize)
        self.stones = Array(repeating: .empty, count: boardSize * boardSize)
        refreshFromBridge()
        Task { await warmUp() }
    }

    private func warmUp() async {
        await engine.warmUp()
        mcts = MCTS(boardSize: boardSize, evaluator: engine)
        modelReady = true
        statusMessage = "Ready"
        #if DEBUG
        await selfCheck()
        #endif
        // Kick off analysis / AI if appropriate for the opening position.
        await advance()
    }

    #if DEBUG
    /// One-time end-to-end Core ML sanity check logged at startup (G3/G4).
    /// On an empty board the game is ~balanced, so Black's win% should sit near
    /// the middle and the score lead near komi. Logged via os_log("GoLearner").
    private func selfCheck() async {
        guard let r = await evaluateCurrent() else {
            os_log("selfCheck: evaluation FAILED", log: .default, type: .error)
            return
        }
        let (best, prob) = bestPolicyMove(r)
        let bx = best.map { $0 % boardSize } ?? -1
        let by = best.map { $0 / boardSize } ?? -1
        os_log("GoLearner selfCheck OK: policyCount=%d bestMove=(%d,%d) p=%.3f winToMove=%.3f whiteLead=%.2f own[0]=%.3f",
               log: .default, type: .info,
               r.policy.count, bx, by, prob, r.winProbToMove, r.whiteLead, r.whiteOwnership.first ?? 0)

        if let mcts {
            let gen = generation
            if let s = await mcts.search(rootBridge: bridge, playouts: 16, shouldContinue: { gen == self.generation }) {
                let sbx = s.bestMove.map { $0 % boardSize } ?? -1
                let sby = s.bestMove.map { $0 / boardSize } ?? -1
                os_log("GoLearner selfCheck MCTS: playouts=%d bestMove=(%d,%d) blackWin=%.3f whiteLead=%.2f",
                       log: .default, type: .info, s.playouts, sbx, sby, s.blackWinProb, s.whiteLead)
            }
        }
    }
    #endif

    // MARK: - Intent

    func newGame() {
        generation += 1
        analysisTask?.cancel()
        bridge.reset(withBoardSize: Int32(boardSize), komi: komi)
        analysis = nil
        refreshFromBridge()
        statusMessage = modelReady ? "New game" : statusMessage
        Task { await advance() }
    }

    /// Human tapping an intersection.
    func humanPlay(x: Int, y: Int) {
        guard !thinking else { return }
        guard !gameOver else { return }
        guard currentPlayerKind == .human else { return }
        guard bridge.playX(Int32(x), y: Int32(y), color: sideToMove) else {
            statusMessage = "Illegal move"
            return
        }
        generation += 1
        refreshFromBridge()
        Task { await advance() }
    }

    func humanPass() {
        guard !thinking, !gameOver, currentPlayerKind == .human else { return }
        bridge.pass(for: sideToMove)
        generation += 1
        refreshFromBridge()
        Task { await advance() }
    }

    func undo() {
        guard !thinking else { return }
        guard bridge.undo() else { return }
        generation += 1
        analysisTask?.cancel()
        analysis = nil
        refreshFromBridge()
        Task { await advance() }
    }

    func setPlayer(_ kind: PlayerKind, for color: GoColor) {
        if color == .black { blackPlayer = kind } else { whitePlayer = kind }
        Task { await advance() }
    }

    func toggleAnalysis() {
        analysisEnabled.toggle()
        if !analysisEnabled { analysis = nil }
        Task { await advance() }
    }

    // MARK: - Engine driving

    private var currentPlayerKind: PlayerKind {
        sideToMove == .black ? blackPlayer : whitePlayer
    }

    /// Decide what the engine should do next: play the AI's move, refresh the
    /// analysis overlay, or nothing. Re-entrant-safe via the generation token.
    private func advance() async {
        guard modelReady else { return }
        if gameOver {
            statusMessage = gameResultText ?? "Game over"
            return
        }

        if currentPlayerKind == .ai {
            await playAIMove()
        } else if analysisEnabled {
            await runAnalysis()
        }
    }

    private func playAIMove() async {
        guard let mcts else { return }
        let gen = generation
        thinking = true
        statusMessage = "\(sideToMove == .black ? "Black" : "White") (AI) thinking…"
        defer { thinking = false }

        let result = await mcts.search(rootBridge: bridge, playouts: aiPlayouts) {
            gen == self.generation
        }
        guard gen == generation else { return } // superseded
        guard let result else {
            statusMessage = "Engine error"
            return
        }

        if analysisEnabled { analysis = nnResult(from: result) }

        if let pos = result.bestMove {
            let x = pos % boardSize, y = pos / boardSize
            if !bridge.playX(Int32(x), y: Int32(y), color: sideToMove) {
                bridge.pass(for: sideToMove) // fallback if somehow illegal
            }
        } else {
            bridge.pass(for: sideToMove)
        }
        generation += 1
        refreshFromBridge()
        await advance() // chain AI-vs-AI or refresh human-turn analysis
    }

    private func runAnalysis() async {
        guard let mcts else { return }
        analysisTask?.cancel()
        let gen = generation
        let task = Task { @MainActor in
            guard let result = await mcts.search(rootBridge: self.bridge, playouts: self.analysisPlayouts, shouldContinue: {
                gen == self.generation && !Task.isCancelled
            }) else { return }
            guard gen == self.generation else { return }
            self.analysis = self.nnResult(from: result)
            self.statusMessage = self.searchSummary(result)
        }
        analysisTask = task
        await task.value
    }

    /// Fill features from the bridge (cheap, main-actor) and evaluate on the engine.
    private func evaluateCurrent() async -> NNResult? {
        let area = boardSize * boardSize
        var spatial = [Float](repeating: 0, count: NNModel.numSpatialFeatures * area)
        var global = [Float](repeating: 0, count: NNModel.numGlobalFeatures)
        spatial.withUnsafeMutableBufferPointer { sp in
            global.withUnsafeMutableBufferPointer { gp in
                bridge.fillSpatial(sp.baseAddress!, global: gp.baseAddress!)
            }
        }
        // Legal mask: board positions then pass (always legal).
        var legalMask = [Bool](repeating: false, count: area + 1)
        for y in 0..<boardSize {
            for x in 0..<boardSize {
                legalMask[y * boardSize + x] = bridge.isLegalX(Int32(x), y: Int32(y), color: sideToMove)
            }
        }
        legalMask[area] = true
        let blackToMove = sideToMove == .black
        return try? await engine.evaluate(spatial: spatial, global: global, legalMask: legalMask, blackToMove: blackToMove)
    }

    private func bestPolicyMove(_ r: NNResult) -> (Int?, Float) {
        var best = -1
        var bestProb: Float = -1
        for pos in 0..<r.policy.count where r.policy[pos] > bestProb {
            bestProb = r.policy[pos]
            best = pos
        }
        return (best >= 0 ? best : nil, max(bestProb, 0))
    }

    /// Map search output onto NNResult so AnalysisOverlay renders visit-based
    /// candidates without any view changes.
    private func nnResult(from s: SearchResult) -> NNResult {
        let blackToMove = sideToMove == .black
        return NNResult(
            policy: s.policy,
            passPolicy: s.passPolicy,
            winProbToMove: blackToMove ? s.blackWinProb : 1 - s.blackWinProb,
            noResultProb: 0,
            whiteScoreMean: s.whiteLead,
            whiteLead: s.whiteLead,
            whiteOwnership: s.whiteOwnership
        )
    }

    private func searchSummary(_ s: SearchResult) -> String {
        let pct = Int((s.blackWinProb * 100).rounded())
        let leadStr = String(format: "%+.1f", s.whiteLead)
        return "B \(pct)%  ·  W lead \(leadStr)  ·  \(s.playouts) po"
    }

    // MARK: - Sync

    private func refreshFromBridge() {
        for y in 0..<boardSize {
            for x in 0..<boardSize {
                stones[y * boardSize + x] = bridge.stoneColor(atX: Int32(x), y: Int32(y))
            }
        }
        sideToMove = bridge.sideToMove
        blackCaptures = Int(bridge.blackCaptures)
        whiteCaptures = Int(bridge.whiteCaptures)
        moveCount = bridge.moveCount
        var lx: Int32 = -1, ly: Int32 = -1
        bridge.lastMoveX(&lx, y: &ly)
        lastMove = lx >= 0 ? (Int(lx), Int(ly)) : nil
        gameOver = bridge.gameFinished
        gameResultText = gameOver ? resultText() : nil
    }

    private func resultText() -> String {
        if bridge.isNoResult { return "No result" }
        let score = bridge.finalWhiteMinusBlackScore
        switch bridge.winner {
        case .black: return String(format: "Black wins by %.1f", -score)
        case .white: return String(format: "White wins by %.1f", score)
        default: return "Draw"
        }
    }
}
