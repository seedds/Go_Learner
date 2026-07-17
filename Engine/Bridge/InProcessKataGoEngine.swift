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
    /// Launch the engine once. `modelPath`/`configPath` point at the bundled
    /// `.bin.gz` net and `default_gtp.cfg`. Safe to call once per process.
    static func launch(modelPath: String, configPath: String) {
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

        // The engine's ScoreValue::initTables() overflows the default 512KB
        // thread stack; pin 1MB like the reference (thread.stackSize=4096*256).
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
        thread.stackSize = 4096 * 256
        thread.name = "KataGoEngine"
        thread.start()
    }

    func sendCommand(_ command: String) { KataGoGTP.sendCommand(command) }
    func getMessageLine() -> String { KataGoGTP.getMessageLine() }
    func clearPendingOutput() { KataGoGTP.clearMessages() }
}
