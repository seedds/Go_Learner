//
//  PhotoImportView.swift
//  GoLearner
//
//  Acquire a board image (Photos library or the in-app camera), run it through
//  the BoardRecognizer, and hand the result to the board editor for
//  tap-to-correct before it's committed. This view owns only acquisition +
//  recognition + status; the actual correction/commit happens in
//  BoardEditorView, so a recognized board and a hand-built one share one path.
//

import SwiftUI
import PhotosUI

struct PhotoImportView: View {
    let recognizer: BoardRecognizer
    /// Called with the recognized position (as an editor seed) once the user is
    /// ready to correct/commit it. The parent opens the editor with it.
    let onRecognized: (EditorBoard) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var photoItem: PhotosPickerItem?
    @State private var showCamera = false
    @State private var phase: Phase = .idle
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

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer()

                Image(systemName: "camera.viewfinder")
                    .font(.system(size: 56))
                    .foregroundStyle(.secondary)
                Text("Import a position from a photo")
                    .font(.headline)
                Text("Shoot or pick a photo of a Go board taken from directly above. "
                     + "You'll be able to fix any misread stones before playing.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)

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
                        Task { await run(on: image) }
                    },
                    onCancel: { showCamera = false }
                )
            }
            .onChange(of: photoItem) { _, item in
                guard let item else { return }
                Task { await loadAndRun(item) }
            }
        }
    }

    private func loadAndRun(_ item: PhotosPickerItem) async {
        phase = .recognizing
        guard let data = try? await item.loadTransferable(type: Data.self),
              let image = Self.cgImage(from: data) else {
            phase = .failed(BoardRecognitionError.invalidImage.userFacingMessage)
            return
        }
        await run(on: image)
    }

    private func run(on image: CGImage) async {
        phase = .recognizing
        do {
            let board = try await recognizer.recognize(image: image, boardSize: boardSize)
            onRecognized(board.toEditorBoard())
            dismiss()
        } catch let error as BoardRecognitionError {
            phase = .failed(error.userFacingMessage)
        } catch {
            phase = .failed(BoardRecognitionError.notRecognized(reason: "\(error)").userFacingMessage)
        }
    }

    /// Decode encoded image data (from a Photos pick) into a CGImage.
    private static func cgImage(from data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}
