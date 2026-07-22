//
//  RecognizedFragment.swift
//  GoLearner
//
//  The result of recognizing a *partial* board from a photo (a corner/edge
//  tesuji diagram), as opposed to RecognizedBoard's full N×N read: a small R×C
//  grid of stones plus the anchor (anchorX, anchorY) telling where the
//  fragment's top-left intersection sits on the full board. Placing it there
//  yields an EditorBoard on the real board size, which flows into the same board
//  editor as a hand-built or full-photo position so the user corrects any
//  misread before committing.
//
//  Deterministic and dependency-light (Foundation + GoColor / EditorBoard), so
//  the placement + side-to-move heuristic are unit-testable without a camera,
//  Vision, or the engine — FragmentAnalysis supplies the real read.
//

import Foundation

struct RecognizedFragment: Equatable {
    /// Fragment grid dimensions (rows from the top, columns from the left).
    let rows: Int
    let cols: Int
    /// Row-major stones within the fragment, index = r*cols + c (r from the top).
    var cells: [GoColor]
    /// Where the fragment's top-left intersection (r=0, c=0) lands on the full
    /// board: 0-indexed column/row, x from left and y from top.
    var anchorX: Int
    var anchorY: Int
    /// Recognizer confidence in [0, 1]; 0 when unknown.
    var confidence: Double

    var blackCount: Int { cells.lazy.filter { $0 == .black }.count }
    var whiteCount: Int { cells.lazy.filter { $0 == .white }.count }

    /// The default side to move from the on-board stone counts, mirroring
    /// RecognizedBoard.defaultToMove:
    ///   - black == white       → Black
    ///   - black == white + 1   → White
    ///   - otherwise            → Black (ambiguous; the user can flip it)
    var defaultToMove: GoColor {
        if blackCount == whiteCount { return .black }
        if blackCount == whiteCount + 1 { return .white }
        return .black
    }

    /// Place the fragment onto a full `boardSize`×`boardSize` editor board at its
    /// anchor. Cells that would fall off the board are dropped (the anchor is
    /// clamped by FragmentAnalysis, so in practice the whole fragment fits). The
    /// result seeds the board editor for tap-to-correct, exactly like a full
    /// recognition or a hand-built position.
    func toEditorBoard(boardSize: Int) -> EditorBoard {
        var grid = [GoColor](repeating: .empty, count: boardSize * boardSize)
        for r in 0..<rows {
            for c in 0..<cols {
                let x = anchorX + c
                let y = anchorY + r
                guard x >= 0, x < boardSize, y >= 0, y < boardSize else { continue }
                grid[y * boardSize + x] = cells[r * cols + c]
            }
        }
        return EditorBoard(cells: grid, size: boardSize, toMove: defaultToMove)
    }
}
