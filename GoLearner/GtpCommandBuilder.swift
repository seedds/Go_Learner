//
//  GtpCommandBuilder.swift
//  GoLearner
//
//  Pure functions that build the GTP command strings GoLearner sends to the
//  vendored KataGo engine. No side effects, no engine dependency — unit-tested
//  in isolation. Coordinates use KataGo's GTP vertex convention (columns A–T
//  skipping I, rows 1…N counted from the bottom).
//

import Foundation

enum GtpCommandBuilder {
    /// Effectively-unbounded visit cap; the engine binds on time first.
    static let unboundedMaxVisits = 1_000_000_000

    /// GTP column letters: A–T with I omitted (KataGo/GTP convention).
    static let columnLetters = Array("ABCDEFGHJKLMNOPQRST")

    /// Convert a 0-indexed (x, yFromTop) on a `size`×`size` board to a GTP vertex
    /// like "Q16". y is measured from the top (GoLearner's board convention);
    /// GTP rows count from the bottom, so the row is `size - yFromTop`.
    static func vertex(x: Int, yFromTop: Int, size: Int) -> String {
        precondition(x >= 0 && x < size && yFromTop >= 0 && yFromTop < size)
        let col = columnLetters[x]
        let row = size - yFromTop
        return "\(col)\(row)"
    }

    static func boardSize(_ size: Int) -> String { "boardsize \(size)" }
    static let clearBoard = "clear_board"
    static func komi(_ komi: Float) -> String { "komi \(komi)" }

    /// Play `color` ("B"/"W") at a 0-indexed (x, yFromTop), or pass.
    static func play(color: String, x: Int, yFromTop: Int, size: Int) -> String {
        "play \(color) \(vertex(x: x, yFromTop: yFromTop, size: size))"
    }
    static func play(color: String, pass: Bool) -> String { "play \(color) pass" }

    static func genmove(color: String) -> String { "genmove \(color)" }

    /// Fixed handicap placement (engine chooses the standard points).
    static func fixedHandicap(_ count: Int) -> String { "fixed_handicap \(count)" }

    /// Load a game from an SGF file at `path`, reconstructing setup stones
    /// (`AB`/`AW`), the side to move (`PL`), and the move list. The engine
    /// tokenizes the command on spaces, so `path` must be space-free.
    static func loadSGF(path: String) -> String { "loadsgf \(path)" }

    static let showboard = "showboard"

    /// KataGo rule setters. `ko` ∈ {SIMPLE,POSITIONAL,SITUATIONAL},
    /// `scoring` ∈ {AREA,TERRITORY}.
    static func setKoRule(_ ko: String) -> String { "kata-set-rule ko \(ko)" }
    static func setScoringRule(_ scoring: String) -> String { "kata-set-rule scoring \(scoring)" }

    /// Cap search for one move. `maxTime` seconds; visits effectively unbounded.
    static func setMaxVisits(_ v: Int) -> String { "kata-set-param maxVisits \(v)" }
    static func setMaxTime(_ t: Float) -> String { "kata-set-param maxTime \(t)" }

    /// One continuous-analysis line requesting per-move info + ownership + a
    /// rootInfo block. `interval` is centiseconds between reports.
    static func analyze(interval: Int, maxMoves: Int) -> String {
        "kata-analyze interval \(interval) maxmoves \(maxMoves) ownership true rootInfo true"
    }
}
