//
//  GIFExportView.swift
//  GoLearner
//
//  A sheet that turns the current game into an animated GIF. Frames are
//  captured on the main actor by the caller; the CoreGraphics/ImageIO encode
//  runs off-main so the UI stays responsive, reporting progress back. Once
//  written, a ShareLink exports the temp .gif via the system share sheet.
//

import SwiftUI

struct GIFExportView: View {
    /// Positions to render (empty board → final move), captured by the caller.
    let frames: [GameGIF.Frame]
    let boardSize: Int

    @Environment(\.dismiss) private var dismiss
    @State private var options = GameGIF.Options()
    @State private var phase: Phase = .configuring

    private enum Phase: Equatable {
        case configuring
        case rendering(Double)
        case done(URL)
        case failed(String)
    }

    var body: some View {
        NavigationStack {
            Form {
                switch phase {
                case .configuring:          optionsSection
                case .rendering(let p):     renderingSection(p)
                case .done(let url):        doneSection(url)
                case .failed(let message):  failedSection(message)
                }
            }
            .navigationTitle("Export GIF")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    // MARK: Sections

    @ViewBuilder
    private var optionsSection: some View {
        Section("Playback") {
            HStack {
                Text("Speed")
                Slider(value: $options.moveDelay, in: 0.2...2.0, step: 0.1)
                Text(String(format: "%.1fs", options.moveDelay))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            HStack {
                Text("Final hold")
                Slider(value: $options.finalHold, in: 0...5, step: 0.5)
                Text(String(format: "%.1fs", options.finalHold))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Toggle("Loop forever", isOn: $options.loops)
        }
        Section("Appearance") {
            Picker("Size", selection: $options.pixelSize) {
                ForEach(GameGIF.PixelSize.allCases) { Text($0.label).tag($0) }
            }
            Toggle("Coordinates", isOn: $options.showCoordinates)
        }
        Section {
            Button {
                render()
            } label: {
                Label("Generate GIF (\(frames.count) frames)", systemImage: "film")
            }
            .disabled(frames.count < 2)
        } footer: {
            if frames.count < 2 {
                Text("Play at least one move to export a GIF.")
            }
        }
    }

    private func renderingSection(_ progress: Double) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                ProgressView(value: progress)
                Text("Rendering \(Int(progress * 100))%")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func doneSection(_ url: URL) -> some View {
        Section {
            ShareLink(item: url, preview: SharePreview("GoLearner game")) {
                Label("Share GIF", systemImage: "square.and.arrow.up")
            }
            Button {
                phase = .configuring
            } label: {
                Label("Adjust settings", systemImage: "slider.horizontal.3")
            }
        } footer: {
            Text("Saved a \(frames.count)-frame animation.")
        }
    }

    private func failedSection(_ message: String) -> some View {
        Section {
            Label(message, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
            Button("Try again") { phase = .configuring }
        }
    }

    // MARK: Encode

    private func render() {
        let frames = self.frames
        let boardSize = self.boardSize
        let options = self.options
        phase = .rendering(0)

        Task.detached(priority: .userInitiated) {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("GoLearner-game.gif")
            try? FileManager.default.removeItem(at: url)
            do {
                try GameGIF.encode(frames, boardSize: boardSize, options: options,
                                   progress: { p in Task { @MainActor in phase = .rendering(p) } },
                                   to: url)
                await MainActor.run { phase = .done(url) }
            } catch {
                await MainActor.run { phase = .failed("Couldn’t create the GIF.") }
            }
        }
    }
}
