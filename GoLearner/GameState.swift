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

/// Ko rule, mirroring KataGo's `Rules::KO_*` integer constants.
enum KoRule: Int, CaseIterable, Identifiable {
    case simple = 0, positional = 1, situational = 2
    var id: Int { rawValue }
    var label: String {
        switch self {
        case .simple: return "Simple"
        case .positional: return "Positional"
        case .situational: return "Situational"
        }
    }
}

/// Scoring rule, mirroring KataGo's `Rules::SCORING_*` integer constants.
enum ScoringRule: Int, CaseIterable, Identifiable {
    case area = 0, territory = 1
    var id: Int { rawValue }
    var label: String { self == .area ? "Area" : "Territory" }
}

@MainActor
@Observable
final class GameState {
    // MARK: Configuration
    let boardSize: Int
    private(set) var komi: Float
    private(set) var koRule: KoRule = .positional
    private(set) var scoringRule: ScoringRule = .area
    /// Fixed handicap stones for the current game (empty for an even game).
    /// These form the replay base: navigation never rewinds below them.
    private(set) var handicapStones: [SGFPoint] = []

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

    // MARK: Review / navigation
    /// Total moves in the live game (the tip of history).
    private(set) var totalMoves: Int = 0
    /// The ply currently being *viewed* (0 = empty board … totalMoves = live tip).
    private(set) var currentPly: Int = 0
    /// True while viewing a past position; the live game is untouched.
    var isReviewing: Bool { reviewBridge != nil }
    var canStepBackward: Bool { currentPly > 0 }
    var canStepForward: Bool { currentPly < totalMoves }
    /// Black's win probability from the latest analysis, or nil if none yet.
    var blackWinrate: Double? {
        guard let a = analysis else { return nil }
        let black = sideToMove == .black ? a.winProbToMove : 1 - a.winProbToMove
        return Double(black)
    }

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
    /// Non-nil while reviewing a past ply; renders instead of `bridge`.
    private var reviewBridge: GoBridge? = nil
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
        reviewBridge = nil
        handicapStones = []              // reset() rebuilds an even-game base
        bridge.reset(withBoardSize: Int32(boardSize), komi: komi)
        analysis = nil
        refreshFromBridge()
        statusMessage = modelReady ? "New game" : statusMessage
        Task { await advance() }
    }

    /// Start a fresh game with new komi/rules and player assignment. Board size
    /// is fixed for the app's lifetime (the bundled model is 19×19); passing a
    /// different size is ignored. A `handicap` of 2…9 places fixed black stones
    /// and makes White move first.
    func configureNewGame(komi: Float, koRule: KoRule, scoringRule: ScoringRule,
                          blackPlayer: PlayerKind, whitePlayer: PlayerKind,
                          handicap: Int = 0) {
        self.komi = komi
        self.koRule = koRule
        self.scoringRule = scoringRule
        self.blackPlayer = blackPlayer
        self.whitePlayer = whitePlayer
        handicapStones = HandicapPoints.fixed(count: handicap, boardSize: boardSize)
        generation += 1
        analysisTask?.cancel()
        reviewBridge = nil
        bridge.reset(withBoardSize: Int32(boardSize), komi: komi,
                     koRule: Int32(koRule.rawValue), scoringRule: Int32(scoringRule.rawValue))
        if !handicapStones.isEmpty { bridge.setupHandicap(handicapStones) }
        analysis = nil
        refreshFromBridge()
        statusMessage = modelReady ? "New game" : statusMessage
        Task { await advance() }
    }

    /// Human tapping an intersection.
    func humanPlay(x: Int, y: Int) {
        guard !thinking else { return }
        guard !isReviewing else { return }   // reviewing a past position is read-only
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
        guard !thinking, !isReviewing, !gameOver, currentPlayerKind == .human else { return }
        bridge.pass(for: sideToMove)
        generation += 1
        refreshFromBridge()
        Task { await advance() }
    }

    func undo() {
        guard !thinking else { return }
        reviewBridge = nil                   // undo always acts on the live game
        guard bridge.undo() else { return }
        generation += 1
        analysisTask?.cancel()
        analysis = nil
        refreshFromBridge()
        Task { await advance() }
    }

    // MARK: Navigation (review past positions without disturbing the live game)

    func stepBackward() { goto(ply: currentPly - 1) }
    func stepForward() { goto(ply: currentPly + 1) }
    func stepToStart() { goto(ply: 0) }
    func stepToEnd() { goto(ply: totalMoves) }

    /// View the position after `ply` moves. `ply == totalMoves` returns to the
    /// live game (review mode off); any earlier ply enters review mode.
    func goto(ply: Int) {
        let target = max(0, min(ply, totalMoves))
        analysisTask?.cancel()
        generation += 1
        if target == totalMoves {
            reviewBridge = nil            // back at the tip: resume the live game
        } else {
            reviewBridge = bridge.snapshot(atPly: target)
        }
        analysis = nil
        refreshFromBridge()
        Task { await advance() }
    }

    func setPlayer(_ kind: PlayerKind, for color: GoColor) {
        if color == .black { blackPlayer = kind } else { whitePlayer = kind }
        Task { await advance() }
    }

    // MARK: - SGF

    /// Serialize the live game (full history, not the reviewed ply) to SGF text.
    func exportSGF() -> String {
        var moves: [SGFMove] = []
        // With a fixed handicap the setup stones are Black's and White moves
        // first, so the recorded move sequence starts with White.
        var color: GoColor = handicapStones.isEmpty ? .black : .white
        for i in 0..<bridge.moveCount {
            var mx: Int32 = -1, my: Int32 = -1
            let isStone = bridge.move(atIndex: i, outX: &mx, outY: &my)
            moves.append(isStone ? .play(color, Int(mx), Int(my)) : .pass(color))
            color = color == .black ? .white : .black
        }
        let game = SGFGame(boardSize: boardSize, komi: komi, moves: moves,
                           handicap: handicapStones.isEmpty ? 0 : handicapStones.count,
                           setupBlack: handicapStones,
                           result: gameOver ? gameResultText : nil)
        return SGF.serialize(game)
    }

    /// Replace the live game with the main line parsed from `text`. Moves that
    /// don't validate against the rules are skipped (best-effort import).
    /// Returns false if the SGF board size differs from this game's size.
    @discardableResult
    func importSGF(_ text: String, koRule: KoRule? = nil, scoringRule: ScoringRule? = nil) -> Bool {
        guard let parsed = try? SGF.parse(text) else { return false }
        guard parsed.boardSize == boardSize else { return false }

        komi = parsed.komi                       // SGF carries komi (KM)
        if let koRule { self.koRule = koRule }    // rules restored from the store
        if let scoringRule { self.scoringRule = scoringRule }
        handicapStones = parsed.setupBlack        // empty for an even game
        generation += 1
        analysisTask?.cancel()
        reviewBridge = nil
        bridge.reset(withBoardSize: Int32(boardSize), komi: komi,
                     koRule: Int32(self.koRule.rawValue), scoringRule: Int32(self.scoringRule.rawValue))
        if !handicapStones.isEmpty { bridge.setupHandicap(handicapStones) }
        for m in parsed.moves {
            if m.isPass {
                bridge.pass(for: m.color)
            } else if !bridge.playX(Int32(m.x), y: Int32(m.y), color: m.color) {
                // Illegal for the current rules/turn — stop the import here
                // rather than silently desynchronizing color/turn order.
                break
            }
        }
        analysis = nil
        refreshFromBridge()
        statusMessage = "Imported \(moveCount) moves"
        Task { await advance() }
        return true
    }

    // MARK: - GIF export

    /// Snapshot every position (empty board → final move) for GIF rendering.
    /// Reads the live game's history, independent of the reviewed ply.
    func gifFrames() -> [GameGIF.Frame] {
        GameGIF.frames(from: bridge)
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

        // While reviewing a past position, never mutate the live game; just
        // (optionally) analyze what's on screen.
        if isReviewing {
            if analysisEnabled { await runAnalysis() }
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
        let rootBridge = activeBridge
        let task = Task { @MainActor in
            guard let result = await mcts.search(rootBridge: rootBridge, playouts: self.analysisPlayouts, shouldContinue: {
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

    /// The bridge that should drive rendering: the review snapshot if we're
    /// looking at a past position, otherwise the live game.
    private var activeBridge: GoBridge { reviewBridge ?? bridge }

    private func refreshFromBridge() {
        let b = activeBridge
        for y in 0..<boardSize {
            for x in 0..<boardSize {
                stones[y * boardSize + x] = b.stoneColor(atX: Int32(x), y: Int32(y))
            }
        }
        sideToMove = b.sideToMove
        blackCaptures = Int(b.blackCaptures)
        whiteCaptures = Int(b.whiteCaptures)
        moveCount = b.moveCount
        totalMoves = bridge.moveCount        // the live tip, regardless of review
        currentPly = b.moveCount
        var lx: Int32 = -1, ly: Int32 = -1
        b.lastMoveX(&lx, y: &ly)
        lastMove = lx >= 0 ? (Int(lx), Int(ly)) : nil
        gameOver = b.gameFinished
        gameResultText = gameOver ? resultText(b) : nil
    }

    private func resultText(_ bridge: GoBridge) -> String {
        if bridge.isNoResult { return "No result" }
        let score = bridge.finalWhiteMinusBlackScore
        switch bridge.winner {
        case .black: return String(format: "Black wins by %.1f", -score)
        case .white: return String(format: "White wins by %.1f", score)
        default: return "Draw"
        }
    }
}
