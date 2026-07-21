//
//  InProcessKataGoEngine.swift
//  GoLearner
//
//  The real GTP transport: launches the vendored KataGo engine's GTP loop on a
//  dedicated large-stack thread and relays commands/lines through the KataGoGTP
//  ObjC++ bridge. Lives with the engine-linked targets (not the pure Swift
//  seam) because it references KataGoGTP + the bundled model/config.
//
//  @unchecked Sendable: it is effectively stateless, delegating to the
//  process-global, thread-safe C++ stream buffers behind KataGoGTP.
//

import Foundation

final class InProcessKataGoEngine: KataGoEngineIO, @unchecked Sendable {
    /// Guards against launching more than one engine per process (the engine and
    /// its GTP I/O buffers are process-global).
    nonisolated(unsafe) private static var launched = false
    private static let launchLock = NSLock()

    /// Launch the engine once. `modelPath`/`configPath` point at the bundled
    /// `.bin.gz` net and `default_gtp.cfg`. Idempotent: safe to call from both
    /// the app's GameState and a hosted test — the second call is a no-op.
    static func launch(modelPath: String, configPath: String) {
        launchLock.lock()
        if launched { launchLock.unlock(); return }
        launched = true
        launchLock.unlock()

        let homeDataDir = NSTemporaryDirectory() + "katago-home"
        try? FileManager.default.createDirectory(atPath: homeDataDir,
                                                 withIntermediateDirectories: true)
        #if targetEnvironment(simulator)
        // Simulator: CoreML/ANE only (device code 100); MLX/GPU crashes there.
        let devices: [NSNumber] = [100]
        #else
        // Device: GPU+ANE mux (0 = MLX/GPU, 100 = CoreML/ANE).
        let devices: [NSNumber] = [0, 100]
        #endif

        // This thread runs the GTP command loop. Beyond ScoreValue::initTables()
        // (which overflows the default 512KB stack), some GTP commands run a whole
        // search INLINE on this thread — notably `final_score` (game-end scoring)
        // via PlayUtils::computeLead → runWholeSearch, layered on top of ~274KB of
        // by-value Board/BoardHistory locals (BoardHistory is ~118KB at
        // COMPILE_MAX_BOARD_LEN=37). 1MB is not enough for that path, so pin 8MB —
        // the desktop main-thread default KataGo is developed against.
        let thread = Thread {
            KataGoGTP.runGTP(modelPath: modelPath,
                             humanModelPath: "",
                             configPath: configPath,
                             deviceAssignments: devices,
                             numSearchThreads: 2,
                             nnMaxBatchSize: 3,
                             maxBoardSizeForNNBuffer: 37,
                             requireExactNNLen: false,
                             homeDataDir: homeDataDir,
                             tunerFull: false,
                             reTune: false)
        }
        thread.stackSize = 4096 * 2048  // 8MB
        thread.name = "KataGoEngine"
        thread.start()
    }

    func sendCommand(_ command: String) { KataGoGTP.sendCommand(command) }
    func getMessageLine() -> String { KataGoGTP.getMessageLine() }
    func clearPendingOutput() { KataGoGTP.clearMessages() }
}
