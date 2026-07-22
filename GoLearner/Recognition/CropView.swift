//
//  CropView.swift
//  GoLearner
//
//  A resizable/draggable crop rectangle over an acquired image, used by the
//  fragment (partial-board) import path to frame just the corner/edge diagram
//  before recognition. Reports the selection as a [0,1]² top-left-origin rect
//  relative to the image — exactly the `cropNormalized` a recognizer expects.
//  Assumes a straight-on shot (axis-aligned crop, no perspective handles); the
//  board editor corrects any residual misread afterward.
//

import SwiftUI

struct CropView: View {
    let image: CGImage
    /// Called with the normalized crop rect ([0,1]², top-left origin) on confirm.
    let onConfirm: (CGRect) -> Void
    let onCancel: () -> Void

    /// The fitted (letterboxed) image frame in view space; set once the layout
    /// size is known. Crop coordinates live in this same view space.
    @State private var imageFrame: CGRect = .zero
    /// Crop rectangle in view space (a sub-rect of `imageFrame`).
    @State private var crop: CGRect = .zero
    /// Crop at the start of a body drag, so translation is applied from the
    /// gesture's origin rather than cumulatively each frame.
    @State private var dragBase: CGRect?

    private let handleHit: CGFloat = 32
    private let minSide: CGFloat = 44

    var body: some View {
        NavigationStack {
            GeometryReader { geo in
                ZStack {
                    Color.black.ignoresSafeArea()

                    Image(decorative: image, scale: 1, orientation: .up)
                        .resizable()
                        .scaledToFit()
                        .frame(width: imageFrame.width, height: imageFrame.height)
                        .position(x: imageFrame.midX, y: imageFrame.midY)

                    if imageFrame != .zero {
                        cropRectangle
                        cornerHandles
                    }
                }
                .onAppear { layout(in: geo.size) }
                .onChange(of: geo.size) { _, size in layout(in: size) }
            }
            .ignoresSafeArea(edges: .bottom)
            .navigationTitle("Frame the fragment")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onCancel() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Use") { onConfirm(normalizedCrop) }
                }
            }
        }
    }

    // MARK: - Crop rectangle + handles

    private var cropRectangle: some View {
        Rectangle()
            .stroke(Color.yellow, lineWidth: 2)
            .background(Color.white.opacity(0.001))     // hit area for the body drag
            .frame(width: crop.width, height: crop.height)
            .position(x: crop.midX, y: crop.midY)
            .gesture(
                DragGesture()
                    .onChanged { value in
                        let base = dragBase ?? crop
                        dragBase = base
                        crop = moved(base, by: value.translation)
                    }
                    .onEnded { _ in dragBase = nil }
            )
    }

    private var cornerHandles: some View {
        ForEach(Corner.allCases, id: \.self) { corner in
            Circle()
                .fill(Color.yellow)
                .frame(width: 16, height: 16)
                .frame(width: handleHit, height: handleHit)     // larger touch target
                .contentShape(Rectangle())
                .position(point(of: corner))
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            crop = resized(crop, corner: corner, to: clampToImage(value.location))
                        }
                )
        }
    }

    private enum Corner: CaseIterable { case topLeft, topRight, bottomLeft, bottomRight }

    private func point(of corner: Corner) -> CGPoint {
        switch corner {
        case .topLeft: return CGPoint(x: crop.minX, y: crop.minY)
        case .topRight: return CGPoint(x: crop.maxX, y: crop.minY)
        case .bottomLeft: return CGPoint(x: crop.minX, y: crop.maxY)
        case .bottomRight: return CGPoint(x: crop.maxX, y: crop.maxY)
        }
    }

    // MARK: - Transforms (view space)

    /// Translate `rect` by `t`, keeping it inside the image frame.
    private func moved(_ rect: CGRect, by t: CGSize) -> CGRect {
        let x = (rect.minX + t.width).clamped(to: imageFrame.minX...(imageFrame.maxX - rect.width))
        let y = (rect.minY + t.height).clamped(to: imageFrame.minY...(imageFrame.maxY - rect.height))
        return CGRect(x: x, y: y, width: rect.width, height: rect.height)
    }

    /// Move one corner to `p` (already clamped to the image), enforcing a minimum
    /// side so the rectangle can't invert or collapse.
    private func resized(_ rect: CGRect, corner: Corner, to p: CGPoint) -> CGRect {
        var minX = rect.minX, minY = rect.minY, maxX = rect.maxX, maxY = rect.maxY
        switch corner {
        case .topLeft: minX = min(p.x, maxX - minSide); minY = min(p.y, maxY - minSide)
        case .topRight: maxX = max(p.x, minX + minSide); minY = min(p.y, maxY - minSide)
        case .bottomLeft: minX = min(p.x, maxX - minSide); maxY = max(p.y, minY + minSide)
        case .bottomRight: maxX = max(p.x, minX + minSide); maxY = max(p.y, minY + minSide)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private func clampToImage(_ p: CGPoint) -> CGPoint {
        CGPoint(x: p.x.clamped(to: imageFrame.minX...imageFrame.maxX),
                y: p.y.clamped(to: imageFrame.minY...imageFrame.maxY))
    }

    // MARK: - Geometry

    /// Fit the image into `container` (letterboxed, matching `.scaledToFit()`) and
    /// seed a centered default crop the first time.
    private func layout(in container: CGSize) {
        let iw = CGFloat(image.width), ih = CGFloat(image.height)
        guard iw > 0, ih > 0, container.width > 0, container.height > 0 else { return }
        let scale = min(container.width / iw, container.height / ih)
        let w = iw * scale, h = ih * scale
        let frame = CGRect(x: (container.width - w) / 2, y: (container.height - h) / 2, width: w, height: h)

        let wasUnset = imageFrame == .zero
        imageFrame = frame
        if wasUnset {
            crop = CGRect(x: frame.minX + w * 0.2, y: frame.minY + h * 0.2, width: w * 0.6, height: h * 0.6)
        }
    }

    /// The crop as a [0,1]² top-left-origin rect on the image itself.
    private var normalizedCrop: CGRect {
        guard imageFrame.width > 0, imageFrame.height > 0 else { return CGRect(x: 0, y: 0, width: 1, height: 1) }
        return CGRect(x: (crop.minX - imageFrame.minX) / imageFrame.width,
                      y: (crop.minY - imageFrame.minY) / imageFrame.height,
                      width: crop.width / imageFrame.width,
                      height: crop.height / imageFrame.height)
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
