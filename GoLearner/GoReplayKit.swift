//
//  GoReplayKit.swift
//  GoLearner
//
//  Swift conveniences over the ObjC++ GoReplay bridge: replay a move list or an
//  SGF main line into stone grids for rendering, review, GIF frames, and library
//  thumbnails — all engine-free, off the single per-process GTP engine.
//
//  Every replay starts from a SetupPosition base (pre-placed black + white
//  stones + side to move); an even game is the empty base, a handicap game is
//  black stones + White to move.
//

import Foundation

/// A single move in a replay: a stone at (x, y) with y from the top, or a pass.
struct ReplayMove: Equatable {
    var x: Int
    var y: Int
    var color: GoColor
    var isPass: Bool

    static func play(_ color: GoColor, _ x: Int, _ y: Int) -> ReplayMove {
        ReplayMove(x: x, y: y, color: color, isPass: false)
    }
    static func pass(_ color: GoColor) -> ReplayMove {
        ReplayMove(x: -1, y: -1, color: color, isPass: true)
    }
}

enum GoReplayKit {
    /// Replay `moves` on top of a `setup` base on a `size` board, applying
    /// KataGo's capture/ko rules. `plyLimit` < 0 replays all; otherwise the
    /// first `plyLimit` moves (for review/GIF frames).
    static func position(size: Int,
                         setup: SetupPosition = .empty,
                         moves: [ReplayMove],
                         plyLimit: Int = -1) -> GoPosition {
        let sbxs = setup.black.map { Int32($0.x) }
        let sbys = setup.black.map { Int32($0.y) }
        let swxs = setup.white.map { Int32($0.x) }
        let swys = setup.white.map { Int32($0.y) }
        let mxs = moves.map { Int32($0.isPass ? -1 : $0.x) }
        let mys = moves.map { Int32($0.isPass ? -1 : $0.y) }
        let mcs = moves.map { Int32($0.color.rawValue) }

        return sbxs.withUnsafeBufferPointer { sbxp in
            sbys.withUnsafeBufferPointer { sbyp in
                swxs.withUnsafeBufferPointer { swxp in
                    swys.withUnsafeBufferPointer { swyp in
                        mxs.withUnsafeBufferPointer { mxp in
                            mys.withUnsafeBufferPointer { myp in
                                mcs.withUnsafeBufferPointer { mcp in
                                    GoReplay.position(
                                        boardSize: Int32(size),
                                        setupBlackXs: setup.black.isEmpty ? nil : sbxp.baseAddress,
                                        setupBlackYs: setup.black.isEmpty ? nil : sbyp.baseAddress,
                                        setupBlackCount: Int32(setup.black.count),
                                        setupWhiteXs: setup.white.isEmpty ? nil : swxp.baseAddress,
                                        setupWhiteYs: setup.white.isEmpty ? nil : swyp.baseAddress,
                                        setupWhiteCount: Int32(setup.white.count),
                                        initialPlayer: Int32(setup.toMove.rawValue),
                                        moveXs: moves.isEmpty ? nil : mxp.baseAddress,
                                        moveYs: moves.isEmpty ? nil : myp.baseAddress,
                                        moveColors: moves.isEmpty ? nil : mcp.baseAddress,
                                        moveCount: Int32(moves.count),
                                        plyLimit: Int32(plyLimit))
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    /// Flat stone grid (index = y*size + x) for a replayed position.
    static func stones(size: Int, setup: SetupPosition = .empty, moves: [ReplayMove],
                       plyLimit: Int = -1) -> [GoColor] {
        let pos = position(size: size, setup: setup, moves: moves, plyLimit: plyLimit)
        return cells(pos)
    }

    /// Map a replayed position's raw bytes to `[GoColor]` (index = y*size + x).
    static func cells(_ pos: GoPosition) -> [GoColor] {
        [UInt8](pos.cells).map { b in
            switch b {
            case 1: return .black
            case 2: return .white
            default: return .empty
            }
        }
    }

    /// Convert parsed SGF moves to replay moves (skips are handled by the bridge).
    static func replayMoves(from sgfMoves: [SGFMove]) -> [ReplayMove] {
        sgfMoves.map { m in
            m.isPass ? .pass(m.color) : .play(m.color, m.x, m.y)
        }
    }

    /// True if `setup`'s stones are physically placeable on a `size` board under
    /// the engine's rule (no overlaps, no zero-liberty group) — i.e. the engine
    /// will accept it via `loadsgf`. Use before committing an edited/recognized
    /// position so the display can't drift from the engine.
    static func isPlaceableSetup(size: Int, setup: SetupPosition) -> Bool {
        let sbxs = setup.black.map { Int32($0.x) }
        let sbys = setup.black.map { Int32($0.y) }
        let swxs = setup.white.map { Int32($0.x) }
        let swys = setup.white.map { Int32($0.y) }
        return sbxs.withUnsafeBufferPointer { sbxp in
            sbys.withUnsafeBufferPointer { sbyp in
                swxs.withUnsafeBufferPointer { swxp in
                    swys.withUnsafeBufferPointer { swyp in
                        GoReplay.isPlaceableSetup(
                            boardSize: Int32(size),
                            setupBlackXs: setup.black.isEmpty ? nil : sbxp.baseAddress,
                            setupBlackYs: setup.black.isEmpty ? nil : sbyp.baseAddress,
                            setupBlackCount: Int32(setup.black.count),
                            setupWhiteXs: setup.white.isEmpty ? nil : swxp.baseAddress,
                            setupWhiteYs: setup.white.isEmpty ? nil : swyp.baseAddress,
                            setupWhiteCount: Int32(setup.white.count))
                    }
                }
            }
        }
    }

    /// True if `candidate` is legal after `setup` + `moves` (engine rules).
    static func isLegal(size: Int, setup: SetupPosition = .empty,
                        moves: [ReplayMove], candidate: ReplayMove) -> Bool {
        if candidate.isPass { return true }
        let sbxs = setup.black.map { Int32($0.x) }
        let sbys = setup.black.map { Int32($0.y) }
        let swxs = setup.white.map { Int32($0.x) }
        let swys = setup.white.map { Int32($0.y) }
        let mxs = moves.map { Int32($0.isPass ? -1 : $0.x) }
        let mys = moves.map { Int32($0.isPass ? -1 : $0.y) }
        let mcs = moves.map { Int32($0.color.rawValue) }
        return sbxs.withUnsafeBufferPointer { sbxp in
            sbys.withUnsafeBufferPointer { sbyp in
                swxs.withUnsafeBufferPointer { swxp in
                    swys.withUnsafeBufferPointer { swyp in
                        mxs.withUnsafeBufferPointer { mxp in
                            mys.withUnsafeBufferPointer { myp in
                                mcs.withUnsafeBufferPointer { mcp in
                                    GoReplay.isLegal(
                                        boardSize: Int32(size),
                                        setupBlackXs: setup.black.isEmpty ? nil : sbxp.baseAddress,
                                        setupBlackYs: setup.black.isEmpty ? nil : sbyp.baseAddress,
                                        setupBlackCount: Int32(setup.black.count),
                                        setupWhiteXs: setup.white.isEmpty ? nil : swxp.baseAddress,
                                        setupWhiteYs: setup.white.isEmpty ? nil : swyp.baseAddress,
                                        setupWhiteCount: Int32(setup.white.count),
                                        initialPlayer: Int32(setup.toMove.rawValue),
                                        moveXs: moves.isEmpty ? nil : mxp.baseAddress,
                                        moveYs: moves.isEmpty ? nil : myp.baseAddress,
                                        moveColors: moves.isEmpty ? nil : mcp.baseAddress,
                                        moveCount: Int32(moves.count),
                                        candidateX: Int32(candidate.x),
                                        candidateY: Int32(candidate.y),
                                        candidateColor: Int32(candidate.color.rawValue))
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    /// Filter `candidates` to those that replay legally in order (best-effort
    /// SGF import): each legal move is applied before checking the next.
    static func legalMoves(size: Int, setup: SetupPosition = .empty,
                           candidates: [ReplayMove]) -> [ReplayMove] {
        var kept: [ReplayMove] = []
        for m in candidates {
            if m.isPass || isLegal(size: size, setup: setup, moves: kept, candidate: m) {
                kept.append(m)
            } else {
                break   // stop at the first illegal move (matches prior import)
            }
        }
        return kept
    }
}
