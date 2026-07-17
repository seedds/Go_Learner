//
//  ContentView.swift
//  GoLearner
//
//  Main screen: player capsules, the board, a status line, and the control
//  strip (analysis toggle, pass, undo, new game).
//

import SwiftUI

struct ContentView: View {
    @Environment(GameState.self) private var game

    var body: some View {
        VStack(spacing: 12) {
            header
            BoardView()
                .padding(.horizontal, 8)
            statusLine
            controlStrip
        }
        .padding(.vertical, 12)
        .background(Color(white: 0.11))
        .foregroundStyle(.white)
    }

    private var header: some View {
        HStack {
            PlayerCapsule(color: .black,
                          kind: game.blackPlayer,
                          captures: game.blackCaptures,
                          isTurn: game.sideToMove == .black) {
                game.setPlayer(game.blackPlayer == .human ? .ai : .human, for: .black)
            }
            Spacer()
            Text("GoLearner")
                .font(.headline)
            Spacer()
            PlayerCapsule(color: .white,
                          kind: game.whitePlayer,
                          captures: game.whiteCaptures,
                          isTurn: game.sideToMove == .white) {
                game.setPlayer(game.whitePlayer == .human ? .ai : .human, for: .white)
            }
        }
        .padding(.horizontal)
    }

    private var statusLine: some View {
        HStack(spacing: 8) {
            if game.thinking {
                ProgressView().controlSize(.small).tint(.white)
            }
            Text(game.statusMessage)
                .font(.subheadline.monospacedDigit().weight(game.gameOver ? .bold : .regular))
                .foregroundStyle(game.gameOver ? Color.yellow : .white.opacity(0.85))
        }
        .frame(height: 20)
    }

    private var controlStrip: some View {
        HStack(spacing: 22) {
            ControlButton(system: game.analysisEnabled ? "sparkles" : "sparkle",
                          label: "Analyze",
                          active: game.analysisEnabled) {
                game.toggleAnalysis()
            }
            ControlButton(system: "arrow.uturn.backward", label: "Undo") {
                game.undo()
            }
            ControlButton(system: "hand.raised", label: "Pass") {
                game.humanPass()
            }
            ControlButton(system: "plus.square.on.square", label: "New") {
                game.newGame()
            }
        }
        .padding(.top, 4)
    }
}

private struct PlayerCapsule: View {
    let color: GoColor
    let kind: PlayerKind
    let captures: Int
    let isTurn: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 6) {
                Circle()
                    .fill(color == .black ? Color.black : Color.white)
                    .frame(width: 16, height: 16)
                    .overlay(Circle().stroke(.gray, lineWidth: 0.5))
                VStack(alignment: .leading, spacing: 0) {
                    Text(kind.rawValue).font(.caption.bold())
                    Text("\(captures)").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule().fill(isTurn ? Color.accentColor.opacity(0.35) : Color.white.opacity(0.08))
            )
            .overlay(
                Capsule().stroke(isTurn ? Color.accentColor : .clear, lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
    }
}

private struct ControlButton: View {
    let system: String
    let label: String
    var active: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: system)
                    .font(.title2)
                Text(label).font(.caption2)
            }
            .foregroundStyle(active ? Color.accentColor : .white)
        }
        .buttonStyle(.plain)
    }
}
