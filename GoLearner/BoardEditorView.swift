//
//  BoardEditorView.swift
//  GoLearner
//
//  The free board editor: hand-place any position (Black / White / Erase), pick
//  whose turn it is, then commit it as a starting position to solve or analyze.
//  Engine-free while editing — it drives a pure EditorBoard and only hands a
//  SetupPosition back on Done. Reuses BoardView's grid/stone/star primitives.
//

import SwiftUI

struct BoardEditorView: View {
    /// The board being edited (seeded by the caller from the current position or
    /// a recognized board).
    @State private var board: EditorBoard
    @State private var tool: EditTool = .black

    /// Validates a candidate setup (placeable under the engine's rule) so Done
    /// can be disabled on an illegal position (e.g. a zero-liberty group).
    let isPlaceable: (SetupPosition) -> Bool
    /// Called with the committed setup when the user taps Done.
    let onCommit: (SetupPosition) -> Void

    @Environment(\.dismiss) private var dismiss

    init(board: EditorBoard,
         isPlaceable: @escaping (SetupPosition) -> Bool,
         onCommit: @escaping (SetupPosition) -> Void) {
        _board = State(initialValue: board)
        self.isPlaceable = isPlaceable
        self.onCommit = onCommit
    }

    private var candidate: SetupPosition { board.toSetup() }
    private var placeable: Bool { isPlaceable(candidate) }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                editorBoard
                    .padding(.horizontal, 8)

                if !placeable {
                    Label("A stone has no liberties — remove or surround it.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
                }

                toolPalette
                turnAndClear
                Spacer(minLength: 0)
            }
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(.systemBackground))
            .foregroundStyle(.primary)
            .navigationTitle("Edit Position")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        onCommit(candidate)
                        dismiss()
                    }
                    .disabled(!placeable)
                }
            }
        }
    }

    // MARK: Board

    private var editorBoard: some View {
        GeometryReader { geo in
            let dim = min(geo.size.width, geo.size.height)
            let n = board.size
            let margin = dim / CGFloat(n + 1)
            let step = (dim - margin) / CGFloat(n)
            let origin = margin / 2 + step / 2

            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 6)
                    .fill(LinearGradient(
                        colors: [Color(red: 0.86, green: 0.68, blue: 0.42),
                                 Color(red: 0.80, green: 0.60, blue: 0.34)],
                        startPoint: .topLeading, endPoint: .bottomTrailing))
                    .shadow(radius: 4)

                BoardGrid(n: n, origin: origin, step: step)
                    .stroke(Color.black.opacity(0.7), lineWidth: 1)

                ForEach(Array(starCoordinates(for: n).enumerated()), id: \.offset) { _, pt in
                    Circle().fill(Color.black.opacity(0.75))
                        .frame(width: step * 0.16, height: step * 0.16)
                        .position(x: origin + CGFloat(pt.0) * step,
                                  y: origin + CGFloat(pt.1) * step)
                }

                ForEach(0..<(n * n), id: \.self) { idx in
                    let c = board.cells[idx]
                    if c != .empty {
                        StoneView(isBlack: c == .black, diameter: step * 0.92)
                            .position(x: origin + CGFloat(idx % n) * step,
                                      y: origin + CGFloat(idx / n) * step)
                    }
                }
            }
            .frame(width: dim, height: dim)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in paint(at: value.location, origin: origin, step: step) }
            )
        }
        .aspectRatio(1, contentMode: .fit)
    }

    /// Map a touch point to an intersection and apply the current tool. Called on
    /// drag-change so a swipe paints multiple stones.
    private func paint(at location: CGPoint, origin: CGFloat, step: CGFloat) {
        let x = Int(((location.x - origin) / step).rounded())
        let y = Int(((location.y - origin) / step).rounded())
        board.apply(tool, x: x, y: y)
    }

    // MARK: Controls

    private var toolPalette: some View {
        HStack(spacing: 10) {
            ForEach(EditTool.allCases) { t in
                Button { tool = t } label: {
                    HStack(spacing: 6) {
                        toolSwatch(t)
                        Text(t.label).font(.subheadline.weight(.medium))
                    }
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(Capsule().fill(tool == t ? Color.accentColor.opacity(0.35)
                                                         : Color.primary.opacity(0.08)))
                    .overlay(Capsule().stroke(tool == t ? Color.accentColor : .clear, lineWidth: 1.5))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.primary)
            }
        }
    }

    @ViewBuilder
    private func toolSwatch(_ t: EditTool) -> some View {
        switch t {
        case .black:
            Circle().fill(Color.black).frame(width: 16, height: 16)
                .overlay(Circle().stroke(.gray, lineWidth: 0.5))
        case .white:
            Circle().fill(Color.white).frame(width: 16, height: 16)
                .overlay(Circle().stroke(.gray, lineWidth: 0.5))
        case .erase:
            Image(systemName: "eraser").font(.footnote)
        }
    }

    private var turnAndClear: some View {
        HStack(spacing: 16) {
            Picker("To move", selection: $board.toMove) {
                Text("Black to play").tag(GoColor.black)
                Text("White to play").tag(GoColor.white)
            }
            .pickerStyle(.segmented)

            Button(role: .destructive) { board.clear() } label: {
                Label("Clear", systemImage: "trash")
            }
            .buttonStyle(.bordered)
            .tint(.red)
            .disabled(board.isEmpty)
        }
        .padding(.horizontal)
    }
}
