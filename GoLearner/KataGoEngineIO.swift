//
//  KataGoEngineIO.swift
//  GoLearner
//
//  Transport abstraction over the engine's GTP I/O, mirroring the reference's
//  `KataGoEngineIO`. Lets `GameSession` be driven by the real in-process engine
//  or by a fake in tests. Pure protocol — no engine dependency here.
//

import Foundation

/// A bidirectional GTP transport: send command strings, read response lines.
protocol KataGoEngineIO: AnyObject, Sendable {
    /// Send a single GTP command (the transport appends the newline).
    func sendCommand(_ command: String)
    /// Block until the next output line is available; returns it without the
    /// trailing newline.
    func getMessageLine() -> String
    /// Drop buffered, not-yet-read output lines from a prior engine run.
    func clearPendingOutput()
}
