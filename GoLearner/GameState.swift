//
//  GameState.swift
//  GoLearner
//
//  The main-actor observable model. After the P0 engine pivot it drives the full
//  vendored KataGo engine in-process over GTP (via GameSession) for AI moves and
//  analysis, and keeps a Swift-side move-list record that GoReplay renders into
//  board positions (live view, review navigation, GIF frames, thumbnails) with
//  KataGo's own rules — no separate stateful C++ board object.
//
//  Ownership split:
//  • GameSession (off-main actor) owns the engine: play/genmove/analyze.
//  • GameState (main actor) owns the move-list record + observable UI state, and
//    keeps the engine in sync (every live move is mirrored to the engine).
//  • GoReplay (stateless) turns the record into stone grids on demand.
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
    /// KataGo GTP `kata-set-rule ko` token.
    var gtpToken: String {
        switch self {
        case .simple: return "SIMPLE"
        case .positional: return "POSITIONAL"
        case .situational: return "SITUATIONAL"
        }
    }
}

/// Scoring rule, mirroring KataGo's `Rules::SCORING_*` integer constants.
enum ScoringRule: Int, CaseIterable, Identifiable {
    case area = 0, territory = 1
    var id: Int { rawValue }
    var label: String { self == .area ? "Area" : "Territory" }
    var gtpToken: String { self == .area ? "AREA" : "TERRITORY" }
}

/// AI thinking level, expressed as a per-move time budget. The engine binds on
/// time (visits are effectively unbounded — see GtpCommandBuilder), so more
/// seconds means a deeper search and stronger play. `.standard` (3s) preserves
/// the app's original device budget. Cases are ordered by ascending time.
enum AIDifficulty: String, CaseIterable, Identifiable {
    case beginner, easy, standard, strong, max

    var id: String { rawValue }

    /// Per-move search budget in seconds (honored in full on device).
    var seconds: Float {
        switch self {
        case .beginner: return 1
        case .easy:     return 2
        case .standard: return 3
        case .strong:   return 6
        case .max:      return 12
        }
    }

    var label: String {
        switch self {
        case .beginner: return "Beginner"
        case .easy:     return "Easy"
        case .standard: return "Standard"
        case .strong:   return "Strong"
        case .max:      return "Max"
        }
    }

    /// Human-readable budget, e.g. "3s per move".
    var detail: String {
        let s = seconds == seconds.rounded() ? String(Int(seconds)) : String(seconds)
        return "\(s)s per move"
    }
}

@MainActor
@Observable
final class GameState {
    // MARK: Configuration
    /// Board dimension for the current game. Mutable across games (a new game or
    /// an SGF import can switch sizes); the engine masks the fixed 37-wide NN
    /// buffer down to this size, so any 2…37 board is supported.
    private(set) var boardSize: Int
    private(set) var komi: Float
    private(set) var koRule: KoRule = .positional
    private(set) var scoringRule: ScoringRule = .area
    /// The setup base for the current game: pre-placed black + white stones and
    /// the side to move from there. Empty/even for a normal game, black stones +
    /// White-to-move for a handicap, arbitrary for an edited/imported puzzle.
    /// This forms the replay base: navigation never rewinds below it.
    private(set) var setup: SetupPosition = .empty

    // MARK: Board state (derived from the move-list record via GoReplay)
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
    /// The ply currently being *viewed* (0 = empty/handicap base … totalMoves = tip).
    private(set) var currentPly: Int = 0
    /// True while viewing a past position; the live game is untouched.
    var isReviewing: Bool { currentPly < totalMoves }
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

    // MARK: Engine + record
    /// Rebuilt when the board size changes (the actor's size is immutable); the
    /// underlying process-global engine is launched once and reused.
    private var session: GameSession
    /// The live game's move record (the tip). Rendering/review replay from this.
    private var moves: [ReplayMove] = []
    private var analysisTask: Task<Void, Never>? = nil
    /// Monotonic token so stale async results are ignored after new moves.
    private var generation: Int = 0

    /// User-selectable AI thinking level, persisted across launches. Drives the
    /// per-move time budget (`aiMaxTime`). Defaults to `.standard` (3s), the
    /// app's original device budget.
    var aiDifficulty: AIDifficulty {
        didSet { UserDefaults.standard.set(aiDifficulty.rawValue, forKey: GameState.aiDifficultyKey) }
    }
    private static let aiDifficultyKey = "aiDifficulty"

    /// Per-move search budget in seconds. The engine binds on time (visits are
    /// unbounded), so this is the AI's strength knob. The simulator runs CoreML
    /// on CPU (AGENTS.md), so cap it there to stay snappy; device honors the
    /// full budget. At `.standard` this reproduces the original 1s(sim)/3s(device).
    #if targetEnvironment(simulator)
    private var aiMaxTime: Float { min(aiDifficulty.seconds, 1.0) }
    private let analysisMaxMoves = 12
    #else
    private var aiMaxTime: Float { aiDifficulty.seconds }
    private let analysisMaxMoves = 30
    #endif

    /// Stop streaming analysis once the reused search tree reaches this many
    /// root visits. Win% has long converged by then; this bounds the tree's
    /// memory (KataGo reuses the tree across reports on a static position).
    private let analysisVisitCap = 50_000

    /// When hosted by the XCTest bundle, the app must NOT launch/drive the
    /// process-global engine: the test owns it, and a second GTP reader would
    /// deadlock on the shared output stream. The board still renders via the
    /// engine-free GoReplay path.
    private static var isRunningUnderTests: Bool {
        NSClassFromString("XCTestCase") != nil
    }

    init(boardSize: Int = 19, komi: Float = 7.5) {
        self.boardSize = boardSize
        self.komi = komi
        let savedDifficulty = UserDefaults.standard.string(forKey: GameState.aiDifficultyKey)
        self.aiDifficulty = savedDifficulty.flatMap(AIDifficulty.init(rawValue:)) ?? .standard
        self.stones = Array(repeating: .empty, count: boardSize * boardSize)
        self.session = GameState.makeSession(boardSize: boardSize,
                                             launchEngine: !GameState.isRunningUnderTests)
        refreshFromRecord()
        if !GameState.isRunningUnderTests {
            Task { await warmUp() }
        }
    }

    /// Build the engine session. Launches the in-process engine unless suppressed
    /// (under tests, where the test owns the single process-global engine).
    private static func makeSession(boardSize: Int, launchEngine: Bool) -> GameSession {
        if launchEngine {
            let bundle = Bundle.main
            let modelPath = bundle.path(forResource: "default_model", ofType: "bin.gz") ?? ""
            let configPath = bundle.path(forResource: "default_gtp", ofType: "cfg") ?? ""
            InProcessKataGoEngine.launch(modelPath: modelPath, configPath: configPath)
        }
        return GameSession(engine: InProcessKataGoEngine(), boardSize: boardSize)
    }

    /// Switch the game to a new board size: rebuild the session (its size is
    /// immutable) against the already-launched engine and resize the render
    /// buffer. Caller is responsible for resetting the engine to the new record.
    private func adoptBoardSize(_ size: Int) {
        guard size != boardSize else { return }
        boardSize = size
        stones = Array(repeating: .empty, count: size * size)
        session = GameState.makeSession(boardSize: size,
                                        launchEngine: !GameState.isRunningUnderTests)
    }

    private func warmUp() async {
        let ok = await session.handshake(timeout: 600)
        guard ok else {
            statusMessage = "Engine failed to start"
            return
        }
        await syncEngineToRecord()
        modelReady = true
        statusMessage = "Ready"
        #if DEBUG
        await selfCheck()
        #endif
        await advance()
    }

    #if DEBUG
    /// One-time end-to-end sanity check logged at startup: an empty-board
    /// genmove should be a corner/star-point opening (>=2 lines from every edge),
    /// the signal that model + inference + GTP decode are all correct.
    private func selfCheck() async {
        guard let vertex = await session.genMove(color: "B") else {
            os_log("selfCheck: genmove FAILED", log: .default, type: .error)
            return
        }
        // Undo the probe move so it doesn't pollute the live game.
        await session.command("undo")
        let pos = GtpAnalysisParser.vertexToPosition(vertex.uppercased(), size: boardSize)
        let x = pos.map { $0 % boardSize } ?? -1
        let y = pos.map { $0 / boardSize } ?? -1
        os_log("GoLearner selfCheck genmove=%{public}@ (%d,%d)", log: .default, type: .info, vertex, x, y)
    }
    #endif

    // MARK: - Intent

    func newGame() {
        generation += 1
        analysisTask?.cancel()
        setup = .empty
        moves = []
        analysis = nil
        refreshFromRecord()
        statusMessage = modelReady ? "New game" : statusMessage
        Task { await resetEngineAndAdvance() }
    }

    /// Start a fresh game with new board size, komi/rules and player assignment.
    /// The engine masks its fixed NN buffer to `size`, so 9/13/19 are supported.
    /// A `handicap` of 2…9 places fixed black stones and makes White move first.
    func configureNewGame(size: Int, komi: Float, koRule: KoRule, scoringRule: ScoringRule,
                          blackPlayer: PlayerKind, whitePlayer: PlayerKind,
                          handicap: Int = 0) {
        adoptBoardSize(size)
        self.komi = komi
        self.koRule = koRule
        self.scoringRule = scoringRule
        self.blackPlayer = blackPlayer
        self.whitePlayer = whitePlayer
        setup = SetupPosition.handicap(count: handicap, boardSize: boardSize)
        generation += 1
        analysisTask?.cancel()
        moves = []
        analysis = nil
        refreshFromRecord()
        statusMessage = modelReady ? "New game" : statusMessage
        Task { await resetEngineAndAdvance() }
    }

    /// Whether `setup` can be committed as a starting position: its stones must
    /// be physically placeable under the engine's rule (no overlaps / zero-liberty
    /// groups), so the engine's `loadsgf` will accept it and the display stays in
    /// sync. An empty setup is always fine.
    func canCommitSetup(_ setup: SetupPosition) -> Bool {
        GoReplayKit.isPlaceableSetup(size: boardSize, setup: setup)
    }

    /// Replace the live game with a hand-edited / recognized starting position:
    /// `setup`'s pre-placed stones become the new base with the given side to
    /// move, and the move record is cleared. The engine is rebuilt via `loadsgf`
    /// (see syncEngineToRecord), then normal play/analysis resumes so the user
    /// can solve the position. Board size + rules are kept from the current game;
    /// pass a `size` to switch (e.g. a recognized 13×13). No-op if the setup
    /// isn't placeable — callers should gate on `canCommitSetup` and surface a
    /// message.
    func commitSetup(_ setup: SetupPosition, size: Int? = nil) {
        if let size { adoptBoardSize(size) }
        guard canCommitSetup(setup) else {
            statusMessage = "Invalid position (a stone has no liberties)"
            return
        }
        self.setup = setup
        generation += 1
        analysisTask?.cancel()
        moves = []
        analysis = nil
        refreshFromRecord()
        statusMessage = modelReady ? "Position set" : statusMessage
        Task { await resetEngineAndAdvance() }
    }

    /// A tap on an intersection. At the live tip this plays the side-to-move's
    /// move for a human player and lets the AI reply as usual. From a past
    /// position it starts a new branch: it plays the stone for whichever color
    /// is to move there (Human *or* AI), discards the moves that followed, and
    /// then resumes normal play — so the AI moves again according to the player
    /// settings for the new position.
    func humanPlay(x: Int, y: Int) {
        guard !thinking, !gameOver else { return }
        let branching = isReviewing
        // At the tip, only a human-controlled side may tap; branching from the
        // past can place either color to seed the new line.
        guard branching || currentPlayerKind == .human else { return }
        let color = sideToMove
        // Branch base: the moves up to the viewed ply (the whole line at the
        // tip). Branching discards the later moves that are being replaced.
        let base = branching ? Array(moves.prefix(currentPly)) : moves
        // GoReplay is the rules authority for legality (same rules as the engine)
        // and works even before the engine finishes loading.
        guard GoReplayKit.isLegal(size: boardSize, setup: setup,
                                  moves: base, candidate: .play(color, x, y)) else {
            statusMessage = "Illegal move"
            return
        }
        moves = base
        moves.append(.play(color, x, y))
        currentPly = moves.count   // play follows the tip so the stone shows immediately
        generation += 1
        if branching {
            analysisTask?.cancel()
            analysis = nil
        }
        refreshFromRecord()
        Task {
            if modelReady {
                if branching {
                    await syncEngineToRecord()   // rebuild the engine to the branched line
                } else {
                    await session.command(GtpCommandBuilder.play(color: gtp(color), x: x, yFromTop: y, size: boardSize))
                }
            }
            await advance()
        }
    }

    func humanPass() {
        guard !thinking, !isReviewing, !gameOver, currentPlayerKind == .human else { return }
        let color = sideToMove
        moves.append(.pass(color))
        currentPly = moves.count   // live play follows the tip
        generation += 1
        refreshFromRecord()
        Task {
            if modelReady { await session.command(GtpCommandBuilder.play(color: gtp(color), pass: true)) }
            await advance()
        }
    }

    // MARK: Navigation (review past positions without disturbing the live game)

    func stepBackward() { goto(ply: currentPly - 1) }
    func stepForward() { goto(ply: currentPly + 1) }
    func stepToStart() { goto(ply: 0) }
    func stepToEnd() { goto(ply: totalMoves) }

    /// View the position after `ply` moves. `ply == totalMoves` returns to the
    /// live tip; any earlier ply enters review mode (render-only, engine idle).
    func goto(ply: Int) {
        let target = max(0, min(ply, totalMoves))
        analysisTask?.cancel()
        generation += 1
        currentPly = target
        analysis = nil
        refreshFromRecord()
        Task { await advance() }
    }

    func setPlayer(_ kind: PlayerKind, for color: GoColor) {
        if color == .black { blackPlayer = kind } else { whitePlayer = kind }
        Task { await advance() }
    }

    // MARK: - SGF

    /// Serialize the live game (full history, not the reviewed ply) to SGF text.
    func exportSGF() -> String {
        var sgfMoves: [SGFMove] = []
        for m in moves {
            sgfMoves.append(m.isPass ? .pass(m.color) : .play(m.color, m.x, m.y))
        }
        let game = SGFGame(boardSize: boardSize, komi: komi, moves: sgfMoves,
                           handicap: setup.handicapCount,
                           setupBlack: setup.black,
                           setupWhite: setup.white,
                           // Emit PL only when the side to move isn't the derived
                           // default, so normal/handicap games stay PL-free and
                           // edited puzzles carry their explicit turn.
                           playerToMove: setup.needsExplicitPlayerToMove ? setup.toMove : nil,
                           result: gameOver ? gameResultText : nil)
        return SGF.serialize(game)
    }

    /// Replace the live game with the main line parsed from `text`, adopting the
    /// SGF's board size (a saved 9×9 game loads into a 19×19 state and vice
    /// versa). Returns false only if the SGF can't be parsed.
    @discardableResult
    func importSGF(_ text: String, koRule: KoRule? = nil, scoringRule: ScoringRule? = nil) -> Bool {
        guard let parsed = try? SGF.parse(text) else { return false }
        adoptBoardSize(parsed.boardSize)
        komi = parsed.komi
        if let koRule { self.koRule = koRule }
        if let scoringRule { self.scoringRule = scoringRule }
        setup = SetupPosition(sgf: parsed)
        // Keep only moves that replay legally (best-effort import), so the record
        // never desyncs from the engine.
        moves = GoReplayKit.legalMoves(size: boardSize, setup: setup,
                                       candidates: GoReplayKit.replayMoves(from: parsed.moves))
        currentPly = moves.count   // open a loaded game at the latest move, not review mode
        generation += 1
        analysisTask?.cancel()
        analysis = nil
        refreshFromRecord()
        statusMessage = "Imported \(moveCount) moves"
        Task { await resetEngineAndAdvance() }
        return true
    }

    // MARK: - GIF export

    /// Snapshot every position (base → final move) for GIF rendering, from the
    /// live record independent of the reviewed ply.
    func gifFrames() -> [GameGIF.Frame] {
        GameGIF.frames(size: boardSize, setup: setup, moves: moves)
    }

    func toggleAnalysis() {
        analysisEnabled.toggle()
        if !analysisEnabled { analysis = nil; analysisTask?.cancel() }
        Task { await advance() }
    }

    // MARK: - Engine driving

    private var currentPlayerKind: PlayerKind {
        sideToMove == .black ? blackPlayer : whitePlayer
    }

    private func gtp(_ color: GoColor) -> String { color == .black ? "B" : "W" }

    /// Reset the engine to a fresh game matching the current config + record,
    /// then advance. Used by new/configure/import.
    private func resetEngineAndAdvance() async {
        guard modelReady else { return }
        await syncEngineToRecord()
        await advance()
    }

    /// Rebuild the engine's position from the current config + move record.
    ///
    /// Two paths, by base:
    /// • Even game (no setup stones): the proven boardsize/komi/rules/clear_board
    ///   + `play` sequence. This is every normal game and the app's default.
    /// • Setup base (handicap or an edited/photo-imported puzzle, incl. explicit
    ///   side-to-move): drive the engine with `loadsgf`, the only GTP path that
    ///   reconstructs arbitrary two-color stones AND the side to move in one shot
    ///   (`set_position` always forces Black to move). Rules/komi are re-applied
    ///   afterward because `loadsgf` adopts the SGF's `RU`/`KM`, and those
    ///   setters preserve the loaded position.
    private func syncEngineToRecord() async {
        if setup.isEmpty {
            await session.command(GtpCommandBuilder.boardSize(boardSize))
            await session.command(GtpCommandBuilder.komi(komi))
            await session.command(GtpCommandBuilder.setKoRule(koRule.gtpToken))
            await session.command(GtpCommandBuilder.setScoringRule(scoringRule.gtpToken))
            await session.command(GtpCommandBuilder.clearBoard)
            for m in moves {
                if m.isPass {
                    await session.command(GtpCommandBuilder.play(color: gtp(m.color), pass: true))
                } else {
                    await session.command(GtpCommandBuilder.play(color: gtp(m.color), x: m.x, yFromTop: m.y, size: boardSize))
                }
            }
            return
        }

        // Setup base: load the full game (setup stones + PL + moves) via a temp
        // SGF, then re-apply the app's komi/rules on top of the loaded position.
        if let url = try? writeTempSGF(exportSGF()) {
            await session.command(GtpCommandBuilder.loadSGF(path: url.path))
            try? FileManager.default.removeItem(at: url)
        }
        await session.command(GtpCommandBuilder.komi(komi))
        await session.command(GtpCommandBuilder.setKoRule(koRule.gtpToken))
        await session.command(GtpCommandBuilder.setScoringRule(scoringRule.gtpToken))
    }

    /// Write `sgf` to a uniquely-named, space-free temp file for `loadsgf`
    /// (GTP splits its command line on spaces, so the path must not contain any).
    private func writeTempSGF(_ sgf: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("golearner-load-\(UUID().uuidString).sgf")
        try sgf.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Decide what to do next: play the AI's move, refresh analysis, or nothing.
    private func advance() async {
        guard modelReady else { return }
        if gameOver {
            statusMessage = gameResultText ?? "Game over"
            return
        }
        if isReviewing { return }   // review is render-only; don't disturb the engine

        if currentPlayerKind == .ai {
            await playAIMove()
        } else if analysisEnabled {
            runAnalysis()
        } else {
            statusMessage = "\(sideToMove == .black ? "Black" : "White") to play"
        }
    }

    private func playAIMove() async {
        let gen = generation
        thinking = true
        statusMessage = "\(sideToMove == .black ? "Black" : "White") (AI) thinking…"
        defer { thinking = false }

        let color = sideToMove
        await session.command(GtpCommandBuilder.setMaxVisits(GtpCommandBuilder.unboundedMaxVisits))
        await session.command(GtpCommandBuilder.setMaxTime(aiMaxTime))
        let vertex = await session.genMove(color: gtp(color))
        guard gen == generation else { return }   // superseded by a user action
        guard let vertex else { statusMessage = "Engine error"; return }

        let up = vertex.uppercased()
        if up == "PASS" || up == "RESIGN" {
            moves.append(.pass(color))
        } else if let pos = GtpAnalysisParser.vertexToPosition(up, size: boardSize) {
            moves.append(.play(color, pos % boardSize, pos / boardSize))
        } else {
            moves.append(.pass(color))
        }
        currentPly = moves.count   // live play follows the tip
        generation += 1
        refreshFromRecord()
        await advance()   // chain AI-vs-AI or refresh human-turn analysis
    }

    /// Stream analysis for the current position: repeatedly read one report,
    /// refresh the overlay + win%/visits readout, and keep going while analysis
    /// stays on and the position is unchanged. The reused search tree makes
    /// visits accumulate and win% converge across reports; stop at the visit cap
    /// so the tree's memory stays bounded. Runs as a detached task (non-blocking)
    /// so it never stalls `advance()`; cancelled by any move/nav/toggle-off.
    private func runAnalysis() {
        analysisTask?.cancel()
        let gen = generation
        let task = Task { @MainActor in
            while self.analysisEnabled, !Task.isCancelled, gen == self.generation {
                guard let parsed = await session.analyzeOnce(interval: 20, maxMoves: analysisMaxMoves, timeout: 20) else {
                    break   // timeout/error: stop rather than hot-spin
                }
                guard gen == self.generation, !Task.isCancelled else { return }
                self.analysis = self.nnResult(from: parsed)
                self.statusMessage = self.analysisSummary(parsed)
                if let visits = parsed.rootVisits, visits >= self.analysisVisitCap { break }
            }
        }
        analysisTask = task
    }

    /// Map an analyze report onto NNResult so AnalysisOverlay + the win-rate bar
    /// render unchanged. Winrate/lead/ownership are converted to the perspective
    /// the UI expects (to-move winrate; White-perspective ownership as before).
    private func nnResult(from a: GtpAnalysis) -> NNResult {
        let area = boardSize * boardSize
        let blackToMove = sideToMove == .black
        // Engine emits winrate/lead from White's perspective; convert to to-move.
        let rootWhiteWin = a.rootWinrateWhite ?? 0.5
        let winToMove = blackToMove ? (1 - rootWhiteWin) : rootWhiteWin
        let whiteLead = a.rootScoreLeadWhite ?? 0
        return NNResult(candidates: NNResult.candidates(from: a.candidates, blackToMove: blackToMove),
                        winProbToMove: winToMove,
                        noResultProb: 0,
                        whiteScoreMean: whiteLead,
                        whiteLead: whiteLead,
                        whiteOwnership: a.ownershipWhite.count == area ? a.ownershipWhite : [Float](repeating: 0, count: area))
    }

    private func analysisSummary(_ a: GtpAnalysis) -> String {
        let blackWin = sideToMove == .black ? (1 - (a.rootWinrateWhite ?? 0.5)) : (a.rootWinrateWhite ?? 0.5)
        let pct = Int((blackWin * 100).rounded())
        let leadStr = String(format: "%+.1f", a.rootScoreLeadWhite ?? 0)
        let visits = a.rootVisits ?? 0
        return "B \(pct)%  ·  W lead \(leadStr)  ·  \(visits) visits"
    }

    // MARK: - Sync

    /// Recompute all observable board state from the move record at `currentPly`.
    private func refreshFromRecord() {
        let pos = GoReplayKit.position(size: boardSize, setup: setup,
                                       moves: moves, plyLimit: currentPly)
        stones = GoReplayKit.cells(pos)
        blackCaptures = Int(pos.blackCaptures)
        whiteCaptures = Int(pos.whiteCaptures)
        lastMove = pos.lastMoveX >= 0 ? (Int(pos.lastMoveX), Int(pos.lastMoveY)) : nil
        moveCount = currentPly
        totalMoves = moves.count
        currentPly = min(currentPly, totalMoves)

        // Side to move at the viewed ply: the setup's base color, flipped once
        // per move applied.
        let baseIsWhite = setup.toMove == .white
        let flips = currentPly % 2 == 1
        sideToMove = (baseIsWhite != flips) ? .white : .black

        // Game over: two consecutive passes at the live tip (area rules).
        gameOver = detectGameOver()
        gameResultText = nil
        if gameOver { Task { await computeResult() } }
    }

    private func detectGameOver() -> Bool {
        guard currentPly == moves.count, moves.count >= 2 else { return false }
        return moves[moves.count - 1].isPass && moves[moves.count - 2].isPass
    }

    /// Ask the engine for the final score once the game ends.
    private func computeResult() async {
        guard modelReady else { return }
        let reply = await session.command("final_score")
        guard reply.ok, let text = reply.lines.first else { return }
        gameResultText = Self.humanResult(text)
        statusMessage = gameResultText ?? "Game over"
    }

    /// Turn a GTP `final_score` reply ("B+3.5", "W+2.5", "0") into display text.
    static func humanResult(_ score: String) -> String {
        let s = score.trimmingCharacters(in: .whitespaces)
        if s == "0" { return "Draw" }
        if s.hasPrefix("B+") { return "Black wins by \(s.dropFirst(2))" }
        if s.hasPrefix("W+") { return "White wins by \(s.dropFirst(2))" }
        return s
    }
}
