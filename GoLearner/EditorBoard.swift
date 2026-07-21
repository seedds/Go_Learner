//
//  EditorBoard.swift
//  GoLearner
//
//  Pure, value-semantic model behind the free board editor: a flat grid of
//  stones plus the side to move, with paint/erase/clear transforms and a
//  conversion to the SetupPosition that GameState commits. Kept free of SwiftUI
//  and the engine so the editing logic is unit-testable in the host bundle; the
//  BoardEditorView is a thin shell over it.
//

import Foundation

/// What a tap places while editing.
enum EditTool: CaseIterable, Identifiable {
    case black, white, erase
    var id: Self { self }
    var label: String {
        switch self {
        case .black: return "Black"
        case .white: return "White"
        case .erase: return "Erase"
        }
    }
    /// The color a tap writes, or nil for erase.
    var color: GoColor? {
        switch self {
        case .black: return .black
        case .white: return .white
        case .erase: return nil
        }
    }
}

/// A board being edited: `cells` is row-major (index = y*size + x), `toMove` is
/// the side to play once the position is committed.
struct EditorBoard: Equatable {
    let size: Int
    private(set) var cells: [GoColor]
    var toMove: GoColor

    init(size: Int, toMove: GoColor = .black) {
        self.size = size
        self.cells = Array(repeating: .empty, count: size * size)
        self.toMove = toMove
    }

    /// Seed the editor from an existing setup base (e.g. re-editing a puzzle or
    /// correcting a recognized board). Stones outside the board are ignored.
    init(setup: SetupPosition, size: Int) {
        self.init(size: size, toMove: setup.toMove)
        for p in setup.black where inBounds(p.x, p.y) { cells[p.y * size + p.x] = .black }
        for p in setup.white where inBounds(p.x, p.y) { cells[p.y * size + p.x] = .white }
    }

    /// Seed the editor from a flat, row-major stone grid (the board currently on
    /// screen), so "Edit Position" starts from what the user sees. A grid whose
    /// length doesn't match `size*size` yields an empty board.
    init(cells: [GoColor], size: Int, toMove: GoColor) {
        self.init(size: size, toMove: toMove)
        if cells.count == size * size { self.cells = cells }
    }

    func inBounds(_ x: Int, _ y: Int) -> Bool { x >= 0 && x < size && y >= 0 && y < size }

    func color(x: Int, y: Int) -> GoColor {
        inBounds(x, y) ? cells[y * size + x] : .empty
    }

    /// Apply `tool` at (x, y): paint black/white or erase. Painting a color over
    /// the same color is a no-op; this never toggles, so dragging a tool across
    /// the board is idempotent (matches a paint metaphor, not a cycle).
    mutating func apply(_ tool: EditTool, x: Int, y: Int) {
        guard inBounds(x, y) else { return }
        cells[y * size + x] = tool.color ?? .empty
    }

    /// Remove every stone (keeps the side to move).
    mutating func clear() {
        cells = Array(repeating: .empty, count: size * size)
    }

    var blackCount: Int { cells.lazy.filter { $0 == .black }.count }
    var whiteCount: Int { cells.lazy.filter { $0 == .white }.count }
    var isEmpty: Bool { blackCount == 0 && whiteCount == 0 }

    /// The setup base for this position: black + white points (row-major) and the
    /// chosen side to move.
    func toSetup() -> SetupPosition {
        var black: [SGFPoint] = []
        var white: [SGFPoint] = []
        for y in 0..<size {
            for x in 0..<size {
                switch cells[y * size + x] {
                case .black: black.append(SGFPoint(x: x, y: y))
                case .white: white.append(SGFPoint(x: x, y: y))
                default: break
                }
            }
        }
        return SetupPosition(black: black, white: white, toMove: toMove)
    }
}
