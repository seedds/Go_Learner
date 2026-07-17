//
//  BoardReconstruction.swift
//  GoLearner
//
//  Replays an SGF main line through the stateless GoReplay bridge to recover the
//  final board position (captures resolved by KataGo's own rules). Used by the
//  library thumbnails. Engine-free and thread-safe, so it needs no main-actor
//  isolation and never touches the single per-process GTP engine.
//

import Foundation

enum BoardReconstruction {
    /// Final stone colors for `game`, index = y * size + x. Illegal moves in the
    /// SGF are skipped (best-effort, matching the import path).
    static func stones(from game: SGFGame) -> [GoColor] {
        GoReplayKit.stones(size: game.boardSize,
                           handicap: game.setupBlack,
                           moves: GoReplayKit.replayMoves(from: game.moves))
    }
}
