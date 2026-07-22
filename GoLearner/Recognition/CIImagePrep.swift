//
//  CIImagePrep.swift
//  GoLearner
//
//  Shared Core Image plumbing for the recognizers: crop a [0,1]² UI-space rect
//  and render a CIImage into a square, top-left-origin grayscale buffer. Both the
//  full-board VisionBoardRecognizer and the FragmentBoardRecognizer prepare their
//  input the same way, so this seam keeps that in one place (the fragment path
//  just skips the full-board quad detection). No Vision / engine here — only the
//  CIImage → GrayImage conversion that BoardImageAnalysis / FragmentAnalysis read.
//

import CoreImage
import CoreGraphics
import Foundation

/// Turns CIImages into the grayscale buffers the pure analyzers consume.
struct CIImagePrep {
    private let context = CIContext(options: [.useSoftwareRenderer: false])

    /// Crop `image` to a [0,1]² top-left-origin rect (UI space). CIImage is
    /// bottom-left origin, so the rect's y is flipped.
    func crop(_ image: CIImage, normalized rect: CGRect) -> CIImage {
        let e = image.extent
        let x = e.origin.x + rect.minX * e.width
        let w = rect.width * e.width
        let h = rect.height * e.height
        let y = e.origin.y + (1 - rect.maxY) * e.height
        return image.cropped(to: CGRect(x: x, y: y, width: w, height: h))
    }

    /// Render `image` into a `side`×`side` grayscale buffer (top-left origin, so
    /// row 0 is the top of the board — matching the grid). Returns nil if
    /// rendering fails.
    func grayscaleBuffer(_ image: CIImage, side: Int) -> GrayImage? {
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
