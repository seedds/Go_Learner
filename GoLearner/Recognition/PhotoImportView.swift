//
//  PhotoImportView.swift
//  GoLearner
//
//  Acquire a board image (Photos library or the in-app camera), run it through
//  the appropriate recognizer, and hand the result to the board editor for
//  tap-to-correct before it's committed. Two modes share this flow:
//    • Whole board — read a full N×N board (VisionBoardRecognizer), as before.
//    • Fragment    — read a partial corner/edge diagram (a tesuji): the user
//      crops to just the fragment, FragmentBoardRecognizer detects its sub-grid
//      and where it sits on the full board, and it's placed onto an N×N editor
//      board.
//  This view owns acquisition + mode + status; the actual correction/commit
//  happens in BoardEditorView, so a recognized board and a hand-built one share
//  one path.
//

import SwiftUI
import PhotosUI

struct PhotoImportView: View {
    let recognizer: BoardRecognizer
    /// Called with the recognized position (as an editor seed) once the user is
    /// ready to correct/commit it. The parent opens the editor with it.
    let onRecognized: (EditorBoard) -> Void

    @Environment(\.dismiss) private var dismiss

    private let fragmentRecognizer = FragmentBoardRecognizer()

    @State private var photoItem: PhotosPickerItem?
    @State private var showCamera = false
    @State private var phase: Phase = .idle
    @State private var mode: ImportMode = .wholeBoard
    /// An acquired image awaiting the crop step (fragment mode). Presenting the
    /// crop sheet; nil when not cropping.
    @State private var pendingCrop: PendingImage?
    /// Board size to read (the user knows it; inferring 9/13/19 from a photo is
    /// unreliable). Seeded from the current game's size.
    @State private var boardSize: Int

    init(recognizer: BoardRecognizer, boardSize: Int, onRecognized: @escaping (EditorBoard) -> Void) {
        self.recognizer = recognizer
        self.onRecognized = onRecognized
        _boardSize = State(initialValue: boardSize)
    }

    private enum Phase: Equatable {
        case idle
        case recognizing
        case failed(String)
    }

    enum ImportMode: Hashable {
        case wholeBoard
        case fragment
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer()

                Image(systemName: "camera.viewfinder")
                    .font(.system(size: 56))
                    .foregroundStyle(.secondary)
                Text("Import a position from a photo")
                    .font(.headline)
                Text(mode == .wholeBoard
                     ? "Shoot or pick a photo of a Go board taken from directly above. "
                       + "You'll be able to fix any misread stones before playing."
                     : "Shoot or pick a photo of a corner/side diagram, then crop to just "
                       + "the fragment. It'll be placed on the board for you to fix and play.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)

                Picker("Mode", selection: $mode) {
                    Text("Whole Board").tag(ImportMode.wholeBoard)
                    Text("Fragment").tag(ImportMode.fragment)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .disabled(phase == .recognizing)

                Picker("Board size", selection: $boardSize) {
                    ForEach(NewGameConfig.sizes, id: \.self) { Text("\($0) × \($0)").tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .disabled(phase == .recognizing)

                if case .recognizing = phase {
                    ProgressView("Recognizing…")
                        .padding(.top, 8)
                } else if case .failed(let message) = phase {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }

                Spacer()

                VStack(spacing: 12) {
                    Button {
                        showCamera = true
                    } label: {
                        Label("Take Photo", systemImage: "camera")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)

                    PhotosPicker(selection: $photoItem, matching: .images) {
                        Label("Choose from Photos", systemImage: "photo.on.rectangle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
                .padding(.horizontal)
                .disabled(phase == .recognizing)
            }
            .padding(.vertical, 24)
            .navigationTitle("Photo Import")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .fullScreenCover(isPresented: $showCamera) {
                CameraCaptureView(
                    onCapture: { image in
                        showCamera = false
                        acquired(image)
                    },
                    onCancel: { showCamera = false }
                )
            }
            .fullScreenCover(item: $pendingCrop) { pending in
                CropView(
                    image: pending.image,
                    onConfirm: { rect in
                        pendingCrop = nil
                        Task { await runFragment(on: pending.image, crop: rect) }
                    },
                    onCancel: { pendingCrop = nil }
                )
            }
            .onChange(of: photoItem) { _, item in
                guard let item else { return }
                Task { await load(item) }
            }
        }
    }

    // MARK: - Acquisition → mode branch

    private func load(_ item: PhotosPickerItem) async {
        phase = .recognizing
        guard let data = try? await item.loadTransferable(type: Data.self),
              let image = Self.cgImage(from: data) else {
            phase = .failed(BoardRecognitionError.invalidImage.userFacingMessage)
            return
        }
        phase = .idle
        acquired(image)
    }

    /// Route a freshly acquired image by mode: whole-board reads immediately;
    /// fragment first goes through the crop step.
    private func acquired(_ image: CGImage) {
        switch mode {
        case .wholeBoard:
            Task { await runWholeBoard(on: image) }
        case .fragment:
            pendingCrop = PendingImage(image: image)
        }
    }

    private func runWholeBoard(on image: CGImage) async {
        phase = .recognizing
        do {
            let board = try await recognizer.recognize(image: image, boardSize: boardSize)
            onRecognized(board.toEditorBoard())
            dismiss()
        } catch {
            phase = .failed(message(for: error))
        }
    }

    private func runFragment(on image: CGImage, crop: CGRect) async {
        phase = .recognizing
        do {
            let fragment = try await fragmentRecognizer.recognize(
                image: image, boardSize: boardSize, cropNormalized: crop)
            onRecognized(fragment.toEditorBoard(boardSize: boardSize))
            dismiss()
        } catch {
            phase = .failed(message(for: error))
        }
    }

    private func message(for error: Error) -> String {
        if let e = error as? BoardRecognitionError { return e.userFacingMessage }
        return BoardRecognitionError.notRecognized(reason: "\(error)").userFacingMessage
    }

    /// Decode encoded image data (from a Photos pick) into a CGImage.
    private static func cgImage(from data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// Wraps an acquired CGImage so it can drive `.fullScreenCover(item:)` for the
    /// crop step (CGImage isn't Identifiable and isn't ours to conform).
    private struct PendingImage: Identifiable {
        let id = UUID()
        let image: CGImage
    }
}
