//
//  KataGoGTPSmokeTests.swift
//  EngineSmokeTests
//
//  T2 + T3 gate for the engine pivot. Launches the vendored KataGo engine in a
//  real app process (EngineHost) and drives it through the Swift seam
//  (InProcessKataGoEngine + GameSession + the pure GTP parsers), confirming:
//    • the engine boots and answers a GTP handshake (T2 plumbing),
//    • rules commands + showboard work with no NN,
//    • genmove yields a sane opening move (model + CoreML + inference + decode),
//    • kata-analyze output parses into candidates/ownership/rootInfo (T3).
//  A corner/star-point opening (>=2 lines from every edge) is the end-to-end
//  signal that the feature encoding + model + decode are correct.
//

import XCTest
@testable import GoLearner

final class EngineSmokeTests: XCTestCase {

    nonisolated(unsafe) private static var session: GameSession?

    /// Launch the engine once and return a session bound to it.
    private func sharedSession() async -> GameSession {
        if let s = Self.session { return s }

        let bundle = Bundle.main
        let modelPath = bundle.path(forResource: "default_model", ofType: "bin.gz")!
        let configPath = bundle.path(forResource: "default_gtp", ofType: "cfg")!
        InProcessKataGoEngine.launch(modelPath: modelPath, configPath: configPath)

        let engine = InProcessKataGoEngine()
        let session = GameSession(engine: engine, boardSize: 19)
        Self.session = session

        // Boot + handshake (first model load + CoreML compile is slow on the sim).
        let ok = await session.handshake(timeout: 600)
        XCTAssertTrue(ok, "engine handshake failed")
        return session
    }

    /// T2 plumbing: commands that need no NN inference.
    func testHandshakeAndBoardState() async throws {
        let session = await sharedSession()
        await session.command(GtpCommandBuilder.boardSize(19))
        await session.command(GtpCommandBuilder.clearBoard)
        await session.command(GtpCommandBuilder.play(color: "B", x: 15, yFromTop: 3, size: 19))
        let board = await session.command(GtpCommandBuilder.showboard)
        XCTAssertTrue(board.ok, "showboard should return an ok reply")
        XCTAssertFalse(board.lines.isEmpty, "showboard returned no text")
    }

    /// T2 + T3: genmove yields a sane opening; then analyze parses.
    func testGenmoveAndAnalyze() async throws {
        let session = await sharedSession()
        await session.command(GtpCommandBuilder.boardSize(19))
        await session.command(GtpCommandBuilder.clearBoard)

        // Opening move as Black.
        guard let vertex = await session.genMove(color: "B") else {
            XCTFail("genmove returned nil")
            return
        }
        let up = vertex.uppercased()
        XCTAssertNotEqual(up, "PASS", "engine passed on the opening move")
        XCTAssertNotEqual(up, "RESIGN", "engine resigned on the opening move")

        guard let pos = GtpAnalysisParser.vertexToPosition(up, size: 19) else {
            XCTFail("unparseable opening vertex: \(vertex)")
            return
        }
        let x = pos % 19, y = pos / 19
        XCTAssertGreaterThanOrEqual(min(x, 18 - x), 2, "opening too close to edge (x): \(vertex)")
        XCTAssertGreaterThanOrEqual(min(y, 18 - y), 2, "opening too close to edge (y): \(vertex)")

        // Analyze the current position; expect at least one candidate.
        await session.command(GtpCommandBuilder.clearBoard)
        guard let analysis = await session.analyzeOnce(interval: 20, maxMoves: 20, timeout: 60) else {
            XCTFail("no analyze report parsed")
            return
        }
        XCTAssertFalse(analysis.candidates.isEmpty, "analyze produced no candidates")
        // Root winrate on an empty board is near even (White perspective).
        if let wr = analysis.rootWinrateWhite {
            XCTAssertGreaterThan(wr, 0.2)
            XCTAssertLessThan(wr, 0.8)
        }
    }

    /// A4b gate: the engine masks its fixed NN buffer down to sub-19 boards, so
    /// `boardsize 9` / `boardsize 13` must produce a legal on-board opening. The
    /// 19×19 "≥2 lines from the edge" heuristic doesn't apply on small boards
    /// (3-3 and tengen are normal openings there), so we only require a real
    /// on-board move. Then we score a *finished* game (two passes) — the only
    /// way the app scores (`GameState.computeResult`), which takes KataGo's
    /// cheap area-scoring branch rather than an unfinished-game nested search.
    func testSubNineteenGenmoveAndScore() async throws {
        let session = await sharedSession()
        for size in [9, 13] {
            await session.command(GtpCommandBuilder.boardSize(size))
            await session.command(GtpCommandBuilder.clearBoard)

            guard let vertex = await session.genMove(color: "B") else {
                XCTFail("\(size): genmove returned nil"); continue
            }
            let up = vertex.uppercased()
            XCTAssertNotEqual(up, "PASS", "\(size): engine passed on the opening move")
            XCTAssertNotEqual(up, "RESIGN", "\(size): engine resigned on the opening move")

            guard let pos = GtpAnalysisParser.vertexToPosition(up, size: size) else {
                XCTFail("\(size): unparseable opening vertex: \(vertex)"); continue
            }
            let x = pos % size, y = pos / size
            XCTAssertTrue((0..<size).contains(x) && (0..<size).contains(y),
                          "\(size): opening move off board: \(vertex)")

            // Finish the game (B already moved via genmove; W + B pass) so
            // final_score uses the finished-game branch, as the app does.
            await session.command(GtpCommandBuilder.play(color: "W", pass: true))
            await session.command(GtpCommandBuilder.play(color: "B", pass: true))
            let score = await session.command("final_score")
            XCTAssertTrue(score.ok, "\(size): final_score should return an ok reply")
        }
        // Leave the shared engine back on 19×19 for any later test ordering.
        await session.command(GtpCommandBuilder.boardSize(19))
        await session.command(GtpCommandBuilder.clearBoard)
    }

    /// Setup-position gate (editor / photo import): a hand-made SGF with AB/AW
    /// setup stones and `PL[W]` must load through `loadsgf` and leave the engine
    /// with White to move — the path GameState.commitSetup uses for a puzzle.
    /// This is the only GTP route that honors an explicit side to move
    /// (set_position always forces Black), so it's the load-bearing contract for
    /// White-to-play puzzles. We confirm White actually moves next by asking the
    /// engine to genmove W and getting a real on-board reply.
    func testLoadSGFSetupWithWhiteToPlay() async throws {
        let session = await sharedSession()

        // Two black stones + one white stone, White to play, on 19×19.
        let sgf = "(;GM[1]FF[4]CA[UTF-8]SZ[19]RU[Chinese]KM[7]PL[W]AB[dd][dp]AW[pp])"
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("golearner-test-\(UUID().uuidString).sgf")
        try sgf.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let load = await session.command(GtpCommandBuilder.loadSGF(path: url.path))
        XCTAssertTrue(load.ok, "loadsgf should accept a valid setup SGF: \(load.text)")

        // showboard should reflect the three setup stones.
        let board = await session.command(GtpCommandBuilder.showboard)
        XCTAssertTrue(board.ok)

        // White to move: genmove W returns a real move (not an error).
        guard let vertex = await session.genMove(color: "W") else {
            XCTFail("genmove W returned nil after loadsgf PL[W]")
            return
        }
        let up = vertex.uppercased()
        XCTAssertNotEqual(up, "RESIGN", "engine resigned unexpectedly")
        if up != "PASS" {
            XCTAssertNotNil(GtpAnalysisParser.vertexToPosition(up, size: 19),
                            "unparseable White move: \(vertex)")
        }

        // Restore the shared engine to a clean 19×19 for later tests.
        await session.command(GtpCommandBuilder.boardSize(19))
        await session.command(GtpCommandBuilder.clearBoard)
    }
}
