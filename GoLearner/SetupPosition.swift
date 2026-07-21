//
//  SetupPosition.swift
//  GoLearner
//
//  The "base" a game is built on before any move is played: pre-placed stones of
//  BOTH colors plus the side to move. This generalizes the old black-only fixed
//  handicap into a first-class setup, which is the shared foundation for the
//  free board editor and photo/camera position import (a recognized/edited board
//  is exactly arbitrary black + white stones + whose turn it is).
//
//  A fixed handicap is just the special case `black = fixed points, white = [],
//  toMove = .white`. Pure Foundation + SGFPoint/GoColor so it compiles into the
//  hostless test bundle alongside the SGF codec and replay bridge.
//

import Foundation

/// A pre-move board base: setup stones per color and the side to move from here.
/// Coordinates are 0-indexed (x from left, y from top), matching SGFPoint.
struct SetupPosition: Equatable {
    var black: [SGFPoint]
    var white: [SGFPoint]
    /// The player to move from this base (Black for an even game, White after a
    /// handicap or when a puzzle is set for White to play).
    var toMove: GoColor

    init(black: [SGFPoint] = [], white: [SGFPoint] = [], toMove: GoColor = .black) {
        self.black = black
        self.white = white
        self.toMove = toMove
    }

    /// The empty even-game base: no stones, Black to move.
    static let empty = SetupPosition()

    /// True when there are no pre-placed stones (a normal game from the start).
    var isEmpty: Bool { black.isEmpty && white.isEmpty }

    /// The side to move implied purely by the stones (no explicit `PL`): a
    /// black-only setup is a handicap so White opens; anything else opens Black.
    /// `init(sgf:)` uses the same rule, so a round-trip through SGF is stable.
    var derivedToMove: GoColor { (!black.isEmpty && white.isEmpty) ? .white : .black }

    /// True when this shape is a conventional fixed/free handicap: black-only
    /// stones with White to move. Only these serialize an SGF `HA` tag.
    var isHandicap: Bool { !black.isEmpty && white.isEmpty && toMove == .white }

    /// SGF `HA` count — the black stone count for a handicap, else 0.
    var handicapCount: Int { isHandicap ? black.count : 0 }

    /// Whether the side to move must be written explicitly (SGF `PL`): only when
    /// it differs from what the stones alone imply (e.g. a White-to-play puzzle,
    /// or a mixed setup that should nonetheless start with White).
    var needsExplicitPlayerToMove: Bool { !isEmpty && toMove != derivedToMove }

    /// A fixed-handicap base: `count` black stones on the standard points, White
    /// to move. Empty/unsupported counts collapse to the even-game base.
    static func handicap(count: Int, boardSize: Int) -> SetupPosition {
        let pts = HandicapPoints.fixed(count: count, boardSize: boardSize)
        return SetupPosition(black: pts, white: [], toMove: pts.isEmpty ? .black : .white)
    }

    /// The setup base carried by an SGF game (its `AB`/`AW` stones + `PL`). When
    /// the file omits `PL` we derive the side to move the way KataGo handicap
    /// games do: a black-only setup (handicap) means White opens; otherwise
    /// (even game, or an ambiguous mixed setup) Black opens.
    init(sgf game: SGFGame) {
        let derived: GoColor = (!game.setupBlack.isEmpty && game.setupWhite.isEmpty) ? .white : .black
        self.init(black: game.setupBlack, white: game.setupWhite,
                  toMove: game.playerToMove ?? derived)
    }
}
