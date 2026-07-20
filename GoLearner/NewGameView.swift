//
//  NewGameView.swift
//  GoLearner
//
//  Sheet for starting a new game: board size, komi, ko/scoring rules, and which
//  side each player (Human/AI) takes. The engine masks its fixed NN buffer to
//  the chosen size, so 9/13/19 all work with the bundled net.
//

import SwiftUI

struct NewGameConfig {
    /// Board sizes offered in the picker (all odd + ≥9, so every handicap 2…9
    /// is placeable — see HandicapPoints).
    static let sizes = [9, 13, 19]

    var size: Int = 19
    var komi: Float = 7.5
    var koRule: KoRule = .positional
    var scoringRule: ScoringRule = .area
    var blackPlayer: PlayerKind = .human
    var whitePlayer: PlayerKind = .ai
    /// Fixed handicap: 0 = even game, 2…9 = handicap stones (White moves first).
    var handicap: Int = 0
}

struct NewGameView: View {
    /// Seeded from the current game so the sheet opens on the live settings.
    @State var config: NewGameConfig
    let onStart: (NewGameConfig) -> Void
    @Environment(\.dismiss) private var dismiss
    /// Remembers the even-game komi so toggling handicap off restores it.
    @State private var evenKomi: Float?

    var body: some View {
        NavigationStack {
            Form {
                Section("Board") {
                    Picker("Size", selection: $config.size) {
                        ForEach(NewGameConfig.sizes, id: \.self) { Text("\($0) × \($0)").tag($0) }
                    }
                    Picker("Handicap", selection: $config.handicap) {
                        Text("None").tag(0)
                        ForEach(Array(HandicapPoints.range), id: \.self) { Text("\($0) stones").tag($0) }
                    }
                    Stepper(value: $config.komi, in: -10...30, step: 0.5) {
                        LabeledContent("Komi", value: komiText)
                    }
                }
                Section("Rules") {
                    Picker("Ko", selection: $config.koRule) {
                        ForEach(KoRule.allCases) { Text($0.label).tag($0) }
                    }
                    Picker("Scoring", selection: $config.scoringRule) {
                        ForEach(ScoringRule.allCases) { Text($0.label).tag($0) }
                    }
                }
                Section("Players") {
                    Picker("Black", selection: $config.blackPlayer) {
                        ForEach(PlayerKind.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    Picker("White", selection: $config.whitePlayer) {
                        ForEach(PlayerKind.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                }
            }
            .navigationTitle("New Game")
            .onChange(of: config.size) { _, new in applySizeKomi(new) }
            .onChange(of: config.handicap) { _, new in applyHandicapKomi(new) }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Start") { onStart(config); dismiss() }
                }
            }
        }
    }

    /// The conventional even-game komi for a board size (area scoring).
    private func defaultKomi(for size: Int) -> Float { size == 9 ? 7.0 : 7.5 }

    /// Switching size resets komi to that size's convention. During a handicap
    /// game komi stays at 0.5, but we update the remembered even-game komi so
    /// toggling handicap off restores the new size's default.
    private func applySizeKomi(_ size: Int) {
        let def = defaultKomi(for: size)
        if config.handicap > 0 { evenKomi = def } else { config.komi = def }
    }

    /// Handicap games conventionally use 0.5 komi; remember and restore the
    /// even-game komi when handicap is turned back off. The stepper stays
    /// editable, so the user can still override.
    private func applyHandicapKomi(_ handicap: Int) {
        if handicap > 0 {
            if evenKomi == nil { evenKomi = config.komi }
            config.komi = 0.5
        } else if let saved = evenKomi {
            config.komi = saved
            evenKomi = nil
        }
    }

    private var komiText: String {
        config.komi.rounded() == config.komi
            ? String(Int(config.komi))
            : String(format: "%.1f", config.komi)
    }
}
