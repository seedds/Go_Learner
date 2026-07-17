//
//  KataGoGTPSmokeTests.swift
//  EngineSmokeTests
//
//  T2 gate for the engine pivot: drive the vendored KataGo engine in-process
//  over GTP and confirm it (a) answers a `version` handshake and (b) generates
//  a sane opening move on the empty board. A corner/handicap-point first move is
//  the end-to-end signal that model load + CoreML conversion + inference + GTP
//  decode are all wired correctly (a broken feature/decode path yields tengen or
//  first-line garbage instead).
//
//  This target links the full engine (libkatago.a + KataGoSwift + MLX) and the
//  KataGoGTP bridge — NOT the legacy Engine/cpp slice — so it validates T1/T2
//  ahead of the T4 app repoint.
//

import XCTest

final class KataGoGTPSmokeTests: XCTestCase {

    /// Launch the engine once for the whole test case on a dedicated thread.
    nonisolated(unsafe) private static var engineStarted = false

    private func startEngineIfNeeded() {
        guard !Self.engineStarted else { return }
        Self.engineStarted = true

        // The net + config are bundled in the EngineHost app (the test host),
        // so read from the main bundle rather than the test bundle.
        let bundle = Bundle.main
        guard let modelPath = bundle.path(forResource: "default_model", ofType: "bin.gz") else {
            XCTFail("default_model.bin.gz missing from host bundle")
            return
        }
        guard let configPath = bundle.path(forResource: "default_gtp", ofType: "cfg") else {
            XCTFail("default_gtp.cfg missing from host bundle")
            return
        }

        // App-writable home-data dir for the MLX autotuner (sandbox root is not
        // writable). Any writable dir works for the test.
        let homeDataDir = NSTemporaryDirectory() + "katago-home"
        try? FileManager.default.createDirectory(atPath: homeDataDir,
                                                 withIntermediateDirectories: true)

        // Simulator: CoreML/ANE only (device code 100). MLX/GPU crashes in the
        // simulator's Metal translation layer.
        let deviceAssignments: [NSNumber] = [100]

        // The engine's GTP loop needs a large stack: ScoreValue::initTables()
        // allocates big tables and overflows the default (512KB) thread stack,
        // SIGSEGV'ing in init. The reference pins 4096*256 (1MB); match it.
        let engineThread = Thread {
            KataGoGTP.runGTP(modelPath: modelPath,
                             humanModelPath: "",
                             configPath: configPath,
                             deviceAssignments: deviceAssignments,
                             numSearchThreads: 2,
                             nnMaxBatchSize: 3,
                             maxBoardSizeForNNBuffer: 37,
                             requireExactNNLen: false,
                             homeDataDir: homeDataDir,
                             tunerFull: false,
                             reTune: false)
        }
        engineThread.stackSize = 4096 * 256
        engineThread.start()
    }

    /// Read GTP output until a full response block (terminated by a blank line)
    /// is seen, or `timeout` elapses. Returns the joined non-empty lines.
    private func readResponse(timeout: TimeInterval) -> String? {
        let deadline = Date().addingTimeInterval(timeout)
        var collected: [String] = []
        while Date() < deadline {
            let line = KataGoGTP.getMessageLine()
            if line.isEmpty {
                if !collected.isEmpty { return collected.joined(separator: "\n") }
                continue
            }
            collected.append(line)
        }
        return collected.isEmpty ? nil : collected.joined(separator: "\n")
    }

    /// T2 plumbing gate: the in-process GTP loop answers commands that need no
    /// NN inference. This isolates the bridge (thread-safe stream buffers +
    /// MainCmds::gtp) from the simulator's CoreML fragility.
    func testGTPHandshakeAndBoardState() throws {
        startEngineIfNeeded()
        let bootTimeout: TimeInterval = 600

        KataGoGTP.sendCommand("version")
        guard let version = readResponse(timeout: bootTimeout) else {
            XCTFail("no response to `version` within \(Int(bootTimeout))s")
            return
        }
        XCTAssertTrue(version.contains("="), "GTP version reply should start with `=`: \(version)")

        KataGoGTP.sendCommand("boardsize 19")
        _ = readResponse(timeout: 60)
        KataGoGTP.sendCommand("clear_board")
        _ = readResponse(timeout: 60)
        // play/showboard exercise the rules engine (no NN).
        KataGoGTP.sendCommand("play B Q16")
        _ = readResponse(timeout: 60)
        KataGoGTP.sendCommand("showboard")
        guard let board = readResponse(timeout: 60) else {
            XCTFail("no response to `showboard`")
            return
        }
        XCTAssertTrue(board.contains("="), "showboard reply should start with `=`: \(board)")
    }

    func testVersionHandshakeThenOpeningMove() throws {
        startEngineIfNeeded()

        // The first model load + CoreML conversion + compile can be slow on the
        // simulator's CPU; allow a generous budget.
        let bootTimeout: TimeInterval = 600

        // 1) Handshake.
        KataGoGTP.sendCommand("version")
        guard let version = readResponse(timeout: bootTimeout) else {
            XCTFail("no response to `version` within \(Int(bootTimeout))s")
            return
        }
        XCTAssertTrue(version.contains("="), "GTP version reply should start with `=`: \(version)")

        // 2) Empty-board opening move as Black.
        KataGoGTP.sendCommand("boardsize 19")
        _ = readResponse(timeout: 60)
        KataGoGTP.sendCommand("clear_board")
        _ = readResponse(timeout: 60)
        KataGoGTP.sendCommand("genmove B")
        guard let move = readResponse(timeout: bootTimeout) else {
            XCTFail("no response to `genmove B`")
            return
        }
        // Parse the vertex from a reply like "= Q16".
        let vertex = move.replacingOccurrences(of: "=", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        XCTAssertFalse(vertex.isEmpty, "genmove returned empty: \(move)")
        XCTAssertNotEqual(vertex, "PASS", "engine passed on the opening move")
        XCTAssertNotEqual(vertex, "RESIGN", "engine resigned on the opening move")

        // A strong net opens away from the edges. Column letter (no I) and row.
        let cols = Array("ABCDEFGHJKLMNOPQRST")
        guard let colChar = vertex.first, let colIdx = cols.firstIndex(of: colChar),
              let row = Int(vertex.dropFirst()) else {
            XCTFail("unparseable vertex: \(vertex)")
            return
        }
        let x = colIdx           // 0..18
        let y = row - 1          // 0..18
        let distFromEdgeX = min(x, 18 - x)
        let distFromEdgeY = min(y, 18 - y)
        // A sane opening sits at least 2 lines in on both axes (3rd/4th line
        // openings). Garbage encodings land on line 1 or tengen-only.
        XCTAssertGreaterThanOrEqual(distFromEdgeX, 2, "opening too close to edge (x): \(vertex)")
        XCTAssertGreaterThanOrEqual(distFromEdgeY, 2, "opening too close to edge (y): \(vertex)")
    }
}
