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
}
