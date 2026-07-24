//
//  GameSession.swift
//  GoLearner
//
//  Actor that serializes GTP request/response traffic to the engine over a
//  `KataGoEngineIO` transport. Off the main actor so blocking reads never stall
//  the UI. This is the coordination core the GameState repoint (T4) builds on:
//  it turns "send a command, collect its reply block" and "run one genmove /
//  one analyze report" into async calls, and decodes analyze output through the
//  pure `GtpAnalysisParser`.
//
//  GTP framing: a reply is `= ...` (ok) or `? ...` (error), terminated by a
//  blank line. `kata-analyze` streams multiple lines until interrupted; callers
//  read one report at a time.
//

import Foundation

actor GameSession {
    private let engine: KataGoEngineIO

    init(engine: KataGoEngineIO) {
        self.engine = engine
    }

    /// One GTP reply: the joined payload lines and whether it was `=` (ok).
    struct Reply {
        let ok: Bool
        let lines: [String]
        var text: String { lines.joined(separator: "\n") }
    }

    /// Handshake: read until the first non-empty line (the engine emits its
    /// banner then a `= ` reply to `version`). Call once after launch.
    func handshake(timeout: TimeInterval = 600) -> Bool {
        engine.clearPendingOutput()
        engine.sendCommand("version")
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let line = engine.getMessageLine()
            if line.hasPrefix("=") { return true }
            if line.hasPrefix("?") { return false }
        }
        return false
    }

    /// Send a request/response GTP command and collect its reply block
    /// (terminated by a blank line). Suitable for play/komi/boardsize/genmove/
    /// showboard — NOT for the streaming kata-analyze.
    @discardableResult
    func command(_ command: String, timeout: TimeInterval = 600) -> Reply {
        engine.sendCommand(command)
        var lines: [String] = []
        var ok = true
        var sawStatus = false
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let line = engine.getMessageLine()
            if line.isEmpty {
                if sawStatus { break }   // blank line terminates the reply
                continue
            }
            if !sawStatus {
                ok = line.hasPrefix("=")
                sawStatus = true
                // Strip the "= " / "? " prefix from the first payload line.
                let stripped = String(line.dropFirst(line.hasPrefix("= ") || line.hasPrefix("? ") ? 2 : 1))
                if !stripped.isEmpty { lines.append(stripped) }
            } else {
                lines.append(line)
            }
        }
        return Reply(ok: ok, lines: lines)
    }

    /// Ask the engine to generate a move for `color` ("B"/"W"). Returns the GTP
    /// vertex ("Q16"/"pass"/"resign") or nil on error.
    func genMove(color: String) -> String? {
        let reply = command(GtpCommandBuilder.genmove(color: color))
        guard reply.ok, let v = reply.lines.first?.trimmingCharacters(in: .whitespaces) else {
            return nil
        }
        return v
    }

    /// Run a one-shot analysis: arm `kata-analyze`, read the first report,
    /// then stop the stream with `name` (a no-op command that also flushes).
    /// Returns the parsed analysis, or nil if none arrived before `timeout`.
    /// `size` is the board being analyzed (used to decode vertices/ownership).
    func analyzeOnce(size: Int, interval: Int = 20, maxMoves: Int = 30,
                     timeout: TimeInterval = 30) -> GtpAnalysis? {
        engine.sendCommand(GtpCommandBuilder.setMaxVisits(GtpCommandBuilder.unboundedMaxVisits))
        engine.sendCommand(GtpCommandBuilder.analyze(interval: interval, maxMoves: maxMoves))
        var result: GtpAnalysis?
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let line = engine.getMessageLine()
            if let a = GtpAnalysisParser.parse(line, size: size) {
                result = a
                break
            }
        }
        // Stop the stream: an empty command interrupts kata-analyze; drain to the
        // terminating blank line so the next request/response reply is clean.
        engine.sendCommand("name")
        var drainedStatus = false
        let drainDeadline = Date().addingTimeInterval(5)
        while Date() < drainDeadline {
            let line = engine.getMessageLine()
            if line.isEmpty { if drainedStatus { break } else { continue } }
            if line.hasPrefix("=") || line.hasPrefix("?") { drainedStatus = true }
        }
        engine.clearPendingOutput()
        return result
    }
}
