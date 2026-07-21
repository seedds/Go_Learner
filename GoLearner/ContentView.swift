//
//  ContentView.swift
//  GoLearner
//
//  Main screen: player capsules, the board, a status line, and the control
//  strip (analysis toggle, pass, new game).
//

import SwiftUI
import UniformTypeIdentifiers

/// Wraps captured GIF frames so they can drive a `.sheet(item:)`.
private struct GIFExportRequest: Identifiable {
    let id = UUID()
    let frames: [GameGIF.Frame]
}

/// Wraps an editor seed board so it can drive a `.sheet(item:)`.
private struct EditRequest: Identifiable {
    let id = UUID()
    let board: EditorBoard
}

struct ContentView: View {
    @Environment(GameState.self) private var game
    @Binding var showNewGame: Bool
    @State private var importingSGF = false
    @State private var gifExport: GIFExportRequest?
    @State private var editRequest: EditRequest?
    @State private var showPhotoImport = false
    /// The recognizer feeding photo import: Vision + Core Image heuristic (no
    /// model asset). Any misreads are corrected in the editor before committing.
    private let recognizer: BoardRecognizer = VisionBoardRecognizer()

    /// SGF is plain text; also accept a `.sgf`-extension type where available.
    private var sgfTypes: [UTType] {
        [UTType(filenameExtension: "sgf"), .plainText, .text].compactMap { $0 }
    }

    var body: some View {
        VStack(spacing: 12) {
            header
            WinrateBar(blackWinrate: game.blackWinrate)
                .padding(.horizontal)
            BoardView()
                .padding(.horizontal, 8)
            statusLine
            navigationStrip
            controlStrip
        }
        .padding(.vertical, 12)
        .background(Color(white: 0.11))
        .foregroundStyle(.white)
        .fileImporter(isPresented: $importingSGF, allowedContentTypes: sgfTypes) { result in
            if case .success(let url) = result { loadSGF(from: url) }
        }
        .sheet(item: $gifExport) { request in
            GIFExportView(frames: request.frames, boardSize: game.boardSize)
        }
        .sheet(item: $editRequest) { request in
            BoardEditorView(board: request.board,
                            isPlaceable: { game.canCommitSetup($0) },
                            onCommit: { game.commitSetup($0, size: request.board.size) })
        }
        .sheet(isPresented: $showPhotoImport) {
            PhotoImportView(recognizer: recognizer, boardSize: game.boardSize) { board in
                // Recognized position → open the editor to correct + commit.
                editRequest = EditRequest(board: board)
            }
        }
    }

    /// Seed the editor from the position currently on screen.
    private func startEditing() {
        let board = EditorBoard(cells: game.stones, size: game.boardSize, toMove: game.sideToMove)
        editRequest = EditRequest(board: board)
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
            Menu {
                ShareLink("Share SGF", item: sgfExportURL(),
                          preview: SharePreview("GoLearner game"))
                Button {
                    importingSGF = true
                } label: {
                    Label("Import SGF", systemImage: "square.and.arrow.down")
                }
                Button {
                    gifExport = GIFExportRequest(frames: game.gifFrames())
                } label: {
                    Label("Export GIF", systemImage: "film")
                }
                Button {
                    startEditing()
                } label: {
                    Label("Edit Position", systemImage: "square.and.pencil")
                }
                Button {
                    showPhotoImport = true
                } label: {
                    Label("Import from Photo", systemImage: "camera.viewfinder")
                }
            } label: {
                Text("GoLearner").font(.headline).foregroundStyle(.white)
            }
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

    /// Write the current game to a temp `.sgf` file so ShareLink can export it.
    private func sgfExportURL() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("GoLearner-game.sgf")
        try? game.exportSGF().write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func loadSGF(from url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        game.importSGF(text)
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

    private var navigationStrip: some View {
        HStack(spacing: 28) {
            NavButton(system: "backward.end.fill", disabled: !game.canStepBackward) { game.stepToStart() }
            NavButton(system: "chevron.left", disabled: !game.canStepBackward) { game.stepBackward() }
            Text("\(game.currentPly)/\(game.totalMoves)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(game.isReviewing ? Color.yellow : .white.opacity(0.7))
                .frame(minWidth: 52)
            NavButton(system: "chevron.right", disabled: !game.canStepForward) { game.stepForward() }
            NavButton(system: "forward.end.fill", disabled: !game.canStepForward) { game.stepToEnd() }
        }
    }

    private var controlStrip: some View {
        HStack(spacing: 22) {
            ControlButton(system: game.analysisEnabled ? "sparkles" : "sparkle",
                          label: "Analyze",
                          active: game.analysisEnabled) {
                game.toggleAnalysis()
            }
            ControlButton(system: "hand.raised", label: "Pass") {
                game.humanPass()
            }
            ControlButton(system: "plus.square.on.square", label: "New") {
                showNewGame = true
            }
        }
        .padding(.top, 4)
    }
}

/// Horizontal win-rate bar: black fills from the left, white from the right.
/// Shows a neutral 50/50 split until the first analysis arrives.
private struct WinrateBar: View {
    let blackWinrate: Double?

    var body: some View {
        let black = blackWinrate ?? 0.5
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Rectangle().fill(Color.white)
                Rectangle().fill(Color.black)
                    .frame(width: geo.size.width * black)
                if let wr = blackWinrate {
                    Text("\(Int((wr * 100).rounded()))%")
                        .font(.caption2.monospacedDigit().bold())
                        .foregroundStyle(.white)
                        .padding(.leading, 6)
                }
            }
        }
        .frame(height: 16)
        .clipShape(Capsule())
        .overlay(Capsule().stroke(.gray.opacity(0.4), lineWidth: 0.5))
        .opacity(blackWinrate == nil ? 0.35 : 1)
    }
}

private struct NavButton: View {
    let system: String
    var disabled: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: system).font(.title3)
        }
        .buttonStyle(.plain)
        .foregroundStyle(disabled ? .white.opacity(0.25) : .white)
        .disabled(disabled)
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
