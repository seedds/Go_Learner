//
//  CameraCaptureView.swift
//  GoLearner
//
//  A minimal in-app camera for photographing a Go board: a live preview with a
//  square framing guide and a shutter that captures one still and hands back a
//  CGImage. Wraps AVCaptureSession (no dependency on the recognizer or engine),
//  so the photo-import flow can shoot a board directly. Requires the
//  NSCameraUsageDescription set in project.yml.
//

import SwiftUI
import AVFoundation

/// Presents the camera; calls `onCapture` with a captured image, or `onCancel`.
struct CameraCaptureView: View {
    let onCapture: (CGImage) -> Void
    let onCancel: () -> Void

    @State private var camera = CameraController()
    @State private var authorized = AVCaptureDevice.authorizationStatus(for: .video)

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            switch authorized {
            case .authorized:
                cameraUI
            case .notDetermined:
                ProgressView().tint(.white)
                    .task {
                        let ok = await AVCaptureDevice.requestAccess(for: .video)
                        authorized = ok ? .authorized : .denied
                    }
            default:
                deniedUI
            }
        }
        .onAppear { camera.onCapture = handleCapture }
        .onDisappear { camera.stop() }
    }

    private var cameraUI: some View {
        ZStack {
            CameraPreview(controller: camera)
                .ignoresSafeArea()
                .task { await camera.start() }

            // Square framing guide.
            GeometryReader { geo in
                let side = min(geo.size.width, geo.size.height) * 0.9
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.white.opacity(0.8), lineWidth: 2)
                    .frame(width: side, height: side)
                    .position(x: geo.size.width / 2, y: geo.size.height / 2)
            }
            .allowsHitTesting(false)

            VStack {
                HStack {
                    Button("Cancel") { onCancel() }
                        .foregroundStyle(.white)
                        .padding()
                    Spacer()
                }
                Spacer()
                Text("Frame the whole board, shoot from above")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.85))
                Button {
                    camera.capture()
                } label: {
                    Circle().fill(.white).frame(width: 68, height: 68)
                        .overlay(Circle().stroke(.white.opacity(0.5), lineWidth: 4).padding(-6))
                }
                .padding(.bottom, 28)
                .padding(.top, 8)
            }
        }
    }

    private var deniedUI: some View {
        VStack(spacing: 16) {
            Image(systemName: "camera.fill").font(.largeTitle)
            Text("Camera access is off")
                .font(.headline)
            Text("Enable camera access in Settings to photograph a board, or import from Photos instead.")
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("Close") { onCancel() }
                .buttonStyle(.borderedProminent)
        }
        .foregroundStyle(.white)
        .padding(32)
    }

    private func handleCapture(_ image: CGImage) {
        onCapture(image)
    }
}

/// UIKit preview layer for the capture session.
private struct CameraPreview: UIViewRepresentable {
    let controller: CameraController

    func makeUIView(context: Context) -> PreviewView {
        let v = PreviewView()
        v.videoPreviewLayer.session = controller.session
        v.videoPreviewLayer.videoGravity = .resizeAspectFill
        return v
    }
    func updateUIView(_ uiView: PreviewView, context: Context) {}

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var videoPreviewLayer: AVCaptureVideoPreviewLayer {
            layer as! AVCaptureVideoPreviewLayer
        }
    }
}

/// Owns the AVCaptureSession + photo output and turns a shutter tap into a
/// CGImage delivered on the main actor via `onCapture`.
@MainActor
final class CameraController: NSObject, AVCapturePhotoCaptureDelegate {
    let session = AVCaptureSession()
    private let output = AVCapturePhotoOutput()
    private var configured = false
    /// Serial queue for the blocking start/stop calls (AVCaptureSession is
    /// internally thread-safe; keep session mutation off the main actor).
    private let sessionQueue = DispatchQueue(label: "com.golearner.camera.session")
    var onCapture: ((CGImage) -> Void)?

    /// Configure inputs/outputs once and start running (off the main thread —
    /// `startRunning` blocks). Safe to call on every appear.
    func start() async {
        if !configured { configure() }
        guard !session.isRunning else { return }
        let session = self.session
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            sessionQueue.async {
                session.startRunning()
                cont.resume()
            }
        }
    }

    func stop() {
        guard session.isRunning else { return }
        let session = self.session
        sessionQueue.async { session.stopRunning() }
    }

    private func configure() {
        session.beginConfiguration()
        session.sessionPreset = .photo
        if let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
           let input = try? AVCaptureDeviceInput(device: device),
           session.canAddInput(input) {
            session.addInput(input)
        }
        if session.canAddOutput(output) { session.addOutput(output) }
        session.commitConfiguration()
        configured = true
    }

    func capture() {
        let settings = AVCapturePhotoSettings()
        output.capturePhoto(with: settings, delegate: self)
    }

    nonisolated func photoOutput(_ output: AVCapturePhotoOutput,
                                 didFinishProcessingPhoto photo: AVCapturePhoto,
                                 error: Error?) {
        guard let cg = photo.cgImageRepresentation() else { return }
        // AVCapturePhoto's CGImage is already oriented for the back camera in
        // portrait via its properties; the recognizer works in image space, and
        // the user reframes with the crop step, so pass it straight through.
        Task { @MainActor in self.onCapture?(cg) }
    }
}
