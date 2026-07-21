//
//  RecognizedBoard.swift
//  GoLearner
//
//  The result of recognizing a Go position from a photo: a square grid of
//  stones (row 0 = top of the image), a confidence, and a default side to move
//  derived from the stone counts. Deterministic and dependency-light (Foundation
//  + GoColor), so the conversion + heuristic are unit-testable without a camera,
//  Vision, or the engine.
//
//  Adapted from the reference app's GobanRecogKit `RecognizedBoard`, but keyed on
//  GoLearner's own GoColor / SetupPosition / EditorBoard types: a recognized
//  board flows straight into the same board editor used for hand-built puzzles,
//  where the user corrects any mis-read stones before committing.
//

import Foundation

struct RecognizedBoard: Equatable {
    let size: Int
    /// Row-major stones, index = y*size + x, y from the top (matches GameState's
    /// `stones` and the editor grid).
    var cells: [GoColor]
    /// Recognizer confidence in [0, 1]; 0 when unknown (e.g. the stub).
    var confidence: Double

    init(size: Int, cells: [GoColor], confidence: Double = 0) {
        self.size = size
        self.cells = cells.count == size * size
            ? cells
            : Array(repeating: .empty, count: size * size)
        self.confidence = confidence
    }

    var blackCount: Int { cells.lazy.filter { $0 == .black }.count }
    var whiteCount: Int { cells.lazy.filter { $0 == .white }.count }

    /// The default side to move from the on-board stone counts, mirroring the
    /// reference heuristic:
    ///   - black == white       → Black (even position, Black started)
    ///   - black == white + 1   → White (Black has played one more)
    ///   - otherwise            → Black (ambiguous; user can flip it in the editor)
    var defaultToMove: GoColor {
        if blackCount == whiteCount { return .black }
        if blackCount == whiteCount + 1 { return .white }
        return .black
    }

    /// Seed the board editor from this recognition, so the user corrects and
    /// commits it through the same path as a hand-built position.
    func toEditorBoard() -> EditorBoard {
        EditorBoard(cells: cells, size: size, toMove: defaultToMove)
    }
}
