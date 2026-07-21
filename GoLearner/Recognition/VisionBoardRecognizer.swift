//
//  VisionBoardRecognizer.swift
//  GoLearner
//
//  Heuristic board recognizer built on Vision + Core Image (no model asset, no
//  OpenCV): find the board quadrilateral, perspective-correct it to a square,
//  render to grayscale, then classify each intersection with the pure
//  BoardImageAnalysis core. Board size is supplied by the caller (see
//  BoardRecognizer), so this only has to read stones on the N×N grid; the user
//  corrects any misreads in the editor.
//
//  This is a best-effort first pass: when the board rectangle isn't found it
//  falls back to treating the (cropped) image as the board's bounding box, which
//  works well for straight-on, tightly-framed photos.
//

import CoreImage
import CoreGraphics
import Foundation
import Vision

struct VisionBoardRecognizer: BoardRecognizer {
    /// Side length of the perspective-corrected square used for sampling.
    var correctedSize = 900
    var params = BoardImageAnalysis.Params()

    func recognize(image: CGImage, boardSize: Int, cropNormalized: CGRect?) async throws -> RecognizedBoard {
        let ci = CIImage(cgImage: image)
        let cropped = cropNormalized.map { crop(ci, normalized: $0) } ?? ci

        // Find the board quad; fall back to the image's own extent (a straight-on
        // shot already frames the board).
        let quad = try? await detectBoardQuad(in: cropped)
        let corrected = perspectiveCorrect(cropped, quad: quad, extent: cropped.extent)

        guard let gray = grayscaleBuffer(corrected, side: correctedSize) else {
            throw BoardRecognitionError.invalidImage
        }
        let cells = BoardImageAnalysis.classify(gray, size: boardSize, params: params)
        let confidence = quad == nil ? 0.4 : 0.75
        return RecognizedBoard(size: boardSize, cells: cells, confidence: confidence)
    }

    // MARK: - Core Image helpers

    private let context = CIContext(options: [.useSoftwareRenderer: false])

    /// Crop `image` to a [0,1]² top-left-origin rect (UI space). CIImage is
    /// bottom-left origin, so the rect's y is flipped.
    private func crop(_ image: CIImage, normalized rect: CGRect) -> CIImage {
        let e = image.extent
        let x = e.origin.x + rect.minX * e.width
        let w = rect.width * e.width
        let h = rect.height * e.height
        let y = e.origin.y + (1 - rect.maxY) * e.height
        return image.cropped(to: CGRect(x: x, y: y, width: w, height: h))
    }

    /// Vision rectangle detection → the board's corner quad (image coordinates,
    /// bottom-left origin), or nil if none is confident enough.
    private func detectBoardQuad(in image: CIImage) async throws -> Quad? {
        try await withCheckedThrowingContinuation { cont in
            let request = VNDetectRectanglesRequest { req, err in
                if let err { cont.resume(throwing: err); return }
                guard let obs = (req.results as? [VNRectangleObservation])?
                    .max(by: { $0.confidence < $1.confidence }) else {
                    cont.resume(returning: nil); return
                }
                let e = image.extent
                func pt(_ p: CGPoint) -> CGPoint {
                    CGPoint(x: e.origin.x + p.x * e.width, y: e.origin.y + p.y * e.height)
                }
                cont.resume(returning: Quad(topLeft: pt(obs.topLeft), topRight: pt(obs.topRight),
                                            bottomRight: pt(obs.bottomRight), bottomLeft: pt(obs.bottomLeft)))
            }
            request.minimumAspectRatio = 0.5
            request.maximumAspectRatio = 1.0
            request.minimumSize = 0.2
            request.quadratureTolerance = 30
            request.minimumConfidence = 0.5
            request.maximumObservations = 8

            let handler = VNImageRequestHandler(ciImage: image, options: [:])
            do { try handler.perform([request]) } catch { cont.resume(throwing: error) }
        }
    }

    private struct Quad { var topLeft, topRight, bottomRight, bottomLeft: CGPoint }

    /// Perspective-correct `image` to a rectified board. With a detected `quad`
    /// use CIPerspectiveCorrection; otherwise return the image unchanged (its
    /// extent is treated as the board's bounding box downstream).
    private func perspectiveCorrect(_ image: CIImage, quad: Quad?, extent: CGRect) -> CIImage {
        guard let quad else { return image }
        let filter = CIFilter(name: "CIPerspectiveCorrection")!
        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(CIVector(cgPoint: quad.topLeft), forKey: "inputTopLeft")
        filter.setValue(CIVector(cgPoint: quad.topRight), forKey: "inputTopRight")
        filter.setValue(CIVector(cgPoint: quad.bottomRight), forKey: "inputBottomRight")
        filter.setValue(CIVector(cgPoint: quad.bottomLeft), forKey: "inputBottomLeft")
        return filter.outputImage ?? image
    }

    /// Render `image` into a `side`×`side` grayscale buffer (top-left origin, so
    /// row 0 is the top of the board — matching the grid). Returns nil if
    /// rendering fails.
    private func grayscaleBuffer(_ image: CIImage, side: Int) -> GrayImage? {
        // Scale/letterbox the image into a square of `side`.
        let scaleX = CGFloat(side) / max(image.extent.width, 1)
        let scaleY = CGFloat(side) / max(image.extent.height, 1)
        let scaled = image
            .transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
            .transformed(by: CGAffineTransform(translationX: -image.extent.origin.x * scaleX,
                                               y: -image.extent.origin.y * scaleY))

        let width = side, height = side
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        let cs = CGColorSpaceCreateDeviceRGB()
        let render = CGRect(x: 0, y: 0, width: width, height: height)
        rgba.withUnsafeMutableBytes { raw in
            context.render(scaled, toBitmap: raw.baseAddress!, rowBytes: width * 4,
                           bounds: render, format: .RGBA8, colorSpace: cs)
        }

        // RGBA → luma, flipping vertically (CIContext renders bottom-left origin).
        var gray = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            let srcRow = (height - 1 - y) * width * 4
            let dstRow = y * width
            for x in 0..<width {
                let p = srcRow + x * 4
                let r = Int(rgba[p]), g = Int(rgba[p + 1]), b = Int(rgba[p + 2])
                // Rec. 601 luma.
                gray[dstRow + x] = UInt8((r * 299 + g * 587 + b * 114) / 1000)
            }
        }
        return GrayImage(width: width, height: height, pixels: gray)
    }
}
