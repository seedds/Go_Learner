//
//  LibraryView.swift
//  GoLearner
//
//  The saved-games History tab plus a compact vector board thumbnail. Tapping a
//  game loads its SGF into the shared GameState (via the RootView selection) and
//  calls `onSelect` so RootView can switch to the Play tab; the autosave in
//  RootView writes changes back to the selected row.
//

import SwiftUI
import SwiftData

struct LibraryView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \SavedGame.updatedAt, order: .reverse) private var games: [SavedGame]

    @Binding var selection: SavedGame?
    @Binding var showNewGame: Bool
    /// Called after a game is chosen so the host can reveal the board (Play tab).
    var onSelect: () -> Void

    var body: some View {
        List {
            ForEach(games) { saved in
                Button {
                    selection = saved
                    onSelect()
                } label: {
                    GameRow(saved: saved)
                }
                .buttonStyle(.plain)
                .listRowBackground(saved == selection ? Color.accentColor.opacity(0.15) : nil)
            }
            .onDelete(perform: delete)
        }
        .navigationTitle("Games")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showNewGame = true } label: { Image(systemName: "plus") }
            }
        }
        .overlay {
            if games.isEmpty {
                ContentUnavailableView("No Games", systemImage: "square.grid.2x2",
                                       description: Text("Tap + to start a new game."))
            }
        }
    }

    private func delete(_ offsets: IndexSet) {
        for i in offsets {
            let victim = games[i]
            if victim == selection { selection = nil }
            context.delete(victim)
        }
    }
}

/// A single library row: thumbnail + name + move count / date.
private struct GameRow: View {
    let saved: SavedGame

    var body: some View {
        HStack(spacing: 12) {
            ThumbnailBoard(sgf: saved.sgf, boardSize: saved.boardSize)
                .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(saved.name).font(.body)
                Text(subtitle)
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// e.g. "19×19 · H2 · 14 moves". Handicap is read from the SGF (`HA`) so it
    /// needs no separate SwiftData field / store migration.
    private var subtitle: String {
        var parts = ["\(saved.boardSize)×\(saved.boardSize)"]
        if let handicap = try? SGF.parse(saved.sgf).handicap, handicap > 0 {
            parts.append("H\(handicap)")
        }
        parts.append("\(saved.moveCount) moves")
        return parts.joined(separator: " · ")
    }
}

/// A tiny non-interactive board rendering of a saved position.
struct ThumbnailBoard: View {
    let sgf: String
    let boardSize: Int

    var body: some View {
        Canvas { ctx, size in
            let n = boardSize
            let step = size.width / CGFloat(n)
            let r = step * 0.42
            ctx.fill(Path(CGRect(origin: .zero, size: size)),
                     with: .color(Color(red: 0.84, green: 0.66, blue: 0.40)))
            for (idx, color) in stones.enumerated() where color != .empty {
                let x = CGFloat(idx % n) * step + step / 2
                let y = CGFloat(idx / n) * step + step / 2
                let rect = CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)
                ctx.fill(Path(ellipseIn: rect),
                         with: .color(color == .black ? .black : .white))
            }
        }
        .background(Color(red: 0.84, green: 0.66, blue: 0.40))
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private var stones: [GoColor] {
        guard let game = try? SGF.parse(sgf) else {
            return [GoColor](repeating: .empty, count: boardSize * boardSize)
        }
        return BoardReconstruction.stones(from: game)
    }
}
