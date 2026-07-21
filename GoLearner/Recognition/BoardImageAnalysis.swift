//
//  BoardImageAnalysis.swift
//  GoLearner
//
//  The pure, testable core of the heuristic recognizer: given a grayscale image
//  of an (already perspective-corrected) board and the grid size, classify each
//  intersection as empty / black / white by sampling a patch and comparing its
//  brightness to the board background. No Vision / Core Image / engine here, so
//  it runs on synthetic buffers in the host test bundle; VisionBoardRecognizer
//  supplies the real corrected image.
//

import Foundation

/// A row-major 8-bit grayscale image (0 = black … 255 = white).
struct GrayImage: Equatable {
    let width: Int
    let height: Int
    let pixels: [UInt8]

    init(width: Int, height: Int, pixels: [UInt8]) {
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    func luma(x: Int, y: Int) -> Int {
        guard x >= 0, x < width, y >= 0, y < height else { return 0 }
        return Int(pixels[y * width + x])
    }
}

enum BoardImageAnalysis {
    /// Tunables for classification. Deltas are in luma units (0…255) relative to
    /// the estimated board background; `inset` skips the board border, and
    /// `patchFraction` is the sampled patch radius as a fraction of the cell step.
    struct Params {
        var inset: Double = 0.0          // fraction of width/height to skip at each edge
        var patchFraction: Double = 0.32 // patch radius ÷ cell step
        var blackDelta: Double = 55       // background - mean ≥ this ⇒ black
        var whiteDelta: Double = 45       // mean - background ≥ this ⇒ white
    }

    /// Classify an `size`×`size` grid on `image`. Intersection i spans
    /// [inset, 1-inset] of the buffer, so a corrected image whose square is the
    /// grid's bounding box maps line i to fraction i/(size-1). Returns row-major
    /// cells (index = y*size + x, y from the top).
    static func classify(_ image: GrayImage, size: Int, params: Params = Params()) -> [GoColor] {
        guard size >= 2, image.width > 0, image.height > 0 else {
            return Array(repeating: .empty, count: max(size, 0) * max(size, 0))
        }

        // Intersection pixel centers along each axis.
        let xs = axisCenters(count: size, extent: image.width, inset: params.inset)
        let ys = axisCenters(count: size, extent: image.height, inset: params.inset)

        // Cell step in pixels → patch radius.
        let stepX = size > 1 ? Double(xs[1] - xs[0]) : Double(image.width)
        let stepY = size > 1 ? Double(ys[1] - ys[0]) : Double(image.height)
        let radius = max(1, Int((min(stepX, stepY) * params.patchFraction).rounded()))

        // Patch mean luma at each intersection.
        var means = [Double](repeating: 0, count: size * size)
        for gy in 0..<size {
            for gx in 0..<size {
                means[gy * size + gx] = patchMean(image, cx: xs[gx], cy: ys[gy], radius: radius)
            }
        }

        // Background = median patch luma (robust to a few dark/bright stones and
        // to overall lighting; the board wood dominates most intersections).
        let background = median(means)

        var cells = [GoColor](repeating: .empty, count: size * size)
        for i in 0..<means.count {
            let m = means[i]
            if background - m >= params.blackDelta {
                cells[i] = .black
            } else if m - background >= params.whiteDelta {
                cells[i] = .white
            } else {
                cells[i] = .empty
            }
        }
        return cells
    }

    /// Pixel centers for `count` grid lines spanning [inset, 1-inset] of `extent`.
    static func axisCenters(count: Int, extent: Int, inset: Double) -> [Int] {
        guard count >= 1 else { return [] }
        if count == 1 { return [extent / 2] }
        let lo = inset * Double(extent)
        let hi = (1 - inset) * Double(extent)
        let span = hi - lo
        return (0..<count).map { i in
            Int((lo + span * Double(i) / Double(count - 1)).rounded())
                .clamped(to: 0...(extent - 1))
        }
    }

    /// Mean luma over the square patch of half-width `radius` around (cx, cy).
    private static func patchMean(_ image: GrayImage, cx: Int, cy: Int, radius: Int) -> Double {
        var sum = 0
        var n = 0
        let x0 = max(0, cx - radius), x1 = min(image.width - 1, cx + radius)
        let y0 = max(0, cy - radius), y1 = min(image.height - 1, cy + radius)
        guard x0 <= x1, y0 <= y1 else { return Double(image.luma(x: cx, y: cy)) }
        for y in y0...y1 {
            let row = y * image.width
            for x in x0...x1 {
                sum += Int(image.pixels[row + x])
                n += 1
            }
        }
        return n > 0 ? Double(sum) / Double(n) : 0
    }

    static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count % 2 == 0 ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
