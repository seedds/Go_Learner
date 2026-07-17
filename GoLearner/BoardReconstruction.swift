//
//  BoardReconstruction.swift
//  GoLearner
//
//  Replays an SGF main line through a throwaway GoBridge to recover the final
//  board position (with captures resolved by the real rules). Used by the
//  library thumbnails. Compiled into the test bundle too, so the replay is
//  unit-testable via the bridge.
//
//  Runs on the main actor: GoBridge is single-threaded / main-actor only.
//

import Foundation

extension GoBridge {
    /// Place `points` as black handicap stones (White to move), from Swift
    /// value types. Wraps the C `int*` primitive.
    func setupHandicap(_ points: [SGFPoint]) {
        let xs = points.map { Int32($0.x) }
        let ys = points.map { Int32($0.y) }
        xs.withUnsafeBufferPointer { xp in
            ys.withUnsafeBufferPointer { yp in
                setupHandicap(xs: xp.baseAddress!, ys: yp.baseAddress!, count: Int32(points.count))
            }
        }
    }
}

enum BoardReconstruction {
    /// Final stone colors for `game`, index = y * size + x. Illegal moves in
    /// the SGF are skipped (best-effort, matching the import path).
    @MainActor
    static func stones(from game: SGFGame) -> [GoColor] {
        let size = game.boardSize
        let bridge = GoBridge(boardSize: Int32(size), komi: game.komi)
        if !game.setupBlack.isEmpty {
            bridge.setupHandicap(game.setupBlack)
        }
        for m in game.moves {
            if m.isPass {
                bridge.pass(for: m.color)
            } else {
                _ = bridge.playX(Int32(m.x), y: Int32(m.y), color: m.color)
            }
        }
        var out = [GoColor](repeating: .empty, count: size * size)
        for y in 0..<size {
            for x in 0..<size {
                out[y * size + x] = bridge.stoneColor(atX: Int32(x), y: Int32(y))
            }
        }
        return out
    }
}
