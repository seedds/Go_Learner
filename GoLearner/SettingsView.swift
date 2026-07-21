//
//  SettingsView.swift
//  GoLearner
//
//  App settings sheet. Currently the AI thinking level: a per-move time budget
//  fed straight into the engine's search (GameState.aiMaxTime → kata-set-param
//  maxTime). The choice is persisted in GameState and applied to the next AI
//  move — no restart, no new game required.
//

import SwiftUI

struct SettingsView: View {
    @Environment(GameState.self) private var game
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var game = game
        NavigationStack {
            Form {
                Section {
                    Picker("Thinking Level", selection: $game.aiDifficulty) {
                        ForEach(AIDifficulty.allCases) { level in
                            Text(level.label).tag(level)
                        }
                    }
                    LabeledContent("Time per move", value: game.aiDifficulty.detail)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("AI Difficulty")
                } footer: {
                    Text("More time means a deeper search and stronger play. "
                         + "Takes effect on the AI's next move.")
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
