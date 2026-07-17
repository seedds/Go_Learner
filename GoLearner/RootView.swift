//
//  RootView.swift
//  GoLearner
//
//  Hosts the library sidebar + board detail in a NavigationSplitView, loads a
//  selected saved game into the shared GameState, and autosaves changes back
//  to the selected row. Persistence (SwiftData) lives here, not in GameState.
//

import SwiftUI
import SwiftData

struct RootView: View {
    @Environment(\.modelContext) private var context
    @Environment(GameState.self) private var game
    @Query(sort: \SavedGame.updatedAt, order: .reverse) private var games: [SavedGame]

    @State private var selection: SavedGame?
    @State private var showNewGame = false
    /// Suppresses autosave while we're loading a game into GameState (loading
    /// mutates the same state that would otherwise trigger a write-back).
    @State private var loading = false
    /// Skips the load-on-select when we've just created + configured a game.
    @State private var suppressLoad = false

    var body: some View {
        NavigationSplitView {
            LibraryView(selection: $selection, showNewGame: $showNewGame)
        } detail: {
            ContentView(showNewGame: $showNewGame)
        }
        .task { ensureSelection() }
        .onChange(of: selection) { _, newValue in load(newValue) }
        .onChange(of: game.totalMoves) { _, _ in persist() }
        .onChange(of: game.gameOver) { _, _ in persist() }
        .sheet(isPresented: $showNewGame) {
            NewGameView(config: currentConfig) { config in startNewGame(config) }
        }
    }

    private var currentConfig: NewGameConfig {
        NewGameConfig(komi: game.komi, koRule: game.koRule, scoringRule: game.scoringRule,
                      blackPlayer: game.blackPlayer, whitePlayer: game.whitePlayer,
                      handicap: game.handicapStones.count)
    }

    /// On first launch pick the most recent game, or create one so there's a
    /// persistence target for autosave.
    private func ensureSelection() {
        guard selection == nil else { return }
        if let recent = games.first {
            selection = recent
        } else {
            let saved = SavedGame(name: "Game 1", boardSize: game.boardSize, komi: game.komi)
            context.insert(saved)
            selection = saved
        }
    }

    /// Configure the live game, then create a fresh saved row to autosave into.
    private func startNewGame(_ config: NewGameConfig) {
        game.configureNewGame(komi: config.komi, koRule: config.koRule,
                              scoringRule: config.scoringRule,
                              blackPlayer: config.blackPlayer, whitePlayer: config.whitePlayer,
                              handicap: config.handicap)
        let saved = SavedGame(name: newGameName(), boardSize: game.boardSize, komi: config.komi,
                              koRuleRaw: config.koRule.rawValue,
                              scoringRuleRaw: config.scoringRule.rawValue)
        context.insert(saved)
        suppressLoad = true            // the live game is already configured
        selection = saved
    }

    private func newGameName() -> String {
        let f = DateFormatter()
        f.dateFormat = "MMM d, HH:mm"
        return "Game \(f.string(from: Date()))"
    }

    private func load(_ saved: SavedGame?) {
        if suppressLoad { suppressLoad = false; return }
        guard let saved else { return }
        loading = true
        game.importSGF(saved.sgf,
                       koRule: KoRule(rawValue: saved.koRuleRaw),
                       scoringRule: ScoringRule(rawValue: saved.scoringRuleRaw))
        loading = false
    }

    private func persist() {
        guard !loading, let saved = selection else { return }
        saved.sgf = game.exportSGF()
        saved.moveCount = game.totalMoves
        saved.koRuleRaw = game.koRule.rawValue
        saved.scoringRuleRaw = game.scoringRule.rawValue
        saved.updatedAt = Date()
    }
}
