//
//  FragmentAnalysis.swift
//  GoLearner
//
//  The pure, testable core of the *partial-board* recognizer: given a grayscale
//  image of an (already cropped) board fragment and the full board size N,
//  detect the fragment's own grid lines, classify each intersection, and infer
//  where the fragment sits on the full board (its anchor). The result is a
//  RecognizedFragment that places onto an N×N EditorBoard for tap-to-correct.
//
//  Unlike BoardImageAnalysis (which stretches a *known* N×N grid edge-to-edge),
//  a fragment's line count is unknown, so we detect it. Detection uses a ridge
//  projection: a line filter that responds to thin dark grid lines and ignores
//  solid stone interiors (a stone is not darker than its neighbors a few pixels
//  away; a line is), summed along each axis into a profile whose peaks are the
//  grid lines. No Vision / Core Image / engine here, so it runs on synthetic
//  buffers in the host test bundle; FragmentBoardRecognizer supplies the real
//  cropped image. Detection is best-effort — the board editor is the correction
//  net for any misread line count or anchor.
//

import Foundation

enum FragmentAnalysis {
    /// Tunables for fragment detection + classification.
    struct Params {
        /// Line-filter half-width as a fraction of the buffer side; the ridge
        /// filter compares a pixel to neighbors this far away (≈ grid-line
        /// thickness scale).
        var ridgeSpanFraction: Double = 1.0 / 180.0
        /// A profile peak counts as a grid line when it reaches this fraction of
        /// the profile's maximum.
        var lineThresholdFraction: Double = 0.33
        /// Two detected lines closer than this fraction of the median gap are
        /// merged (guards against a thick line splitting into two peaks).
        var mergeFraction: Double = 0.5
        /// Patch radius ÷ cell step for intersection sampling.
        var patchFraction: Double = 0.32
        /// A side is treated as a board edge (rather than an interior cut) when
        /// the empty margin beyond its outermost line is at least this fraction
        /// of the cell step.
        var edgeMarginFraction: Double = 0.6
        /// Stone classification thresholds (luma units vs the background median).
        var classification = BoardImageAnalysis.Params()
    }

    /// Analyze a cropped fragment on a full `boardSize` board. Returns a
    /// RecognizedFragment; when detection is implausible (fewer than 2 lines on
    /// an axis, or more lines than the board holds) it degrades gracefully by
    /// clamping and centering, leaving the rest to the editor.
    static func analyze(_ image: GrayImage, boardSize: Int, params: Params = Params()) -> RecognizedFragment {
        guard boardSize >= 2, image.width > 2, image.height > 2 else {
            return RecognizedFragment(rows: 0, cols: 0, cells: [], anchorX: 0, anchorY: 0, confidence: 0)
        }

        let span = max(2, Int((Double(min(image.width, image.height)) * params.ridgeSpanFraction).rounded()))
        let colProfile = columnRidgeProfile(image, span: span)
        let rowProfile = rowRidgeProfile(image, span: span)

        var xs = detectLines(colProfile, params: params)
        var ys = detectLines(rowProfile, params: params)

        // Need at least a 2×2 grid to have a meaningful step; otherwise bail to an
        // empty fragment the user can build by hand.
        guard xs.count >= 2, ys.count >= 2 else {
            return RecognizedFragment(rows: 0, cols: 0, cells: [], anchorX: 0, anchorY: 0, confidence: 0)
        }

        // Clamp an over-detection (more lines than the board has) to the first N,
        // rather than produce an unplaceable fragment.
        if xs.count > boardSize { xs = Array(xs.prefix(boardSize)) }
        if ys.count > boardSize { ys = Array(ys.prefix(boardSize)) }

        let cols = xs.count
        let rows = ys.count
        let stepX = medianGap(xs)
        let stepY = medianGap(ys)
        let radius = max(1, Int((min(stepX, stepY) * params.patchFraction).rounded()))

        // Classify each intersection from its patch mean vs the background median
        // (shared with the full-board classifier).
        var means = [Double](repeating: 0, count: rows * cols)
        for r in 0..<rows {
            for c in 0..<cols {
                means[r * cols + c] = BoardImageAnalysis.patchMean(image, cx: xs[c], cy: ys[r], radius: radius)
            }
        }
        let cells = BoardImageAnalysis.classifyMeans(means, params: params.classification)

        // Infer the anchor from the empty margin beyond the outer lines on each
        // side (a board edge leaves whitespace; an interior cut runs to the crop).
        let anchorX = anchorIndex(lineCount: cols, boardSize: boardSize,
                                  loMargin: xs.first!, hiMargin: image.width - 1 - xs.last!,
                                  step: stepX, edgeFraction: params.edgeMarginFraction)
        let anchorY = anchorIndex(lineCount: rows, boardSize: boardSize,
                                  loMargin: ys.first!, hiMargin: image.height - 1 - ys.last!,
                                  step: stepY, edgeFraction: params.edgeMarginFraction)

        let confidence = min(spacingConfidence(xs), spacingConfidence(ys))
        return RecognizedFragment(rows: rows, cols: cols, cells: cells,
                                  anchorX: anchorX, anchorY: anchorY, confidence: confidence)
    }

    // MARK: - Ridge projections

    /// Column profile of "vertical-line-ness": at each pixel, how much darker it
    /// is than the pixels `span` columns to its left and right (0 on flat regions
    /// and solid stone interiors), summed down each column. Peaks mark vertical
    /// grid lines.
    static func columnRidgeProfile(_ image: GrayImage, span: Int) -> [Double] {
        var profile = [Double](repeating: 0, count: image.width)
        for x in span..<(image.width - span) {
            var sum = 0.0
            for y in 0..<image.height {
                let here = image.luma(x: x, y: y)
                let left = image.luma(x: x - span, y: y)
                let right = image.luma(x: x + span, y: y)
                let ridge = min(left, right) - here
                if ridge > 0 { sum += Double(ridge) }
            }
            profile[x] = sum
        }
        return profile
    }

    /// Row profile of "horizontal-line-ness" (see columnRidgeProfile, transposed).
    static func rowRidgeProfile(_ image: GrayImage, span: Int) -> [Double] {
        var profile = [Double](repeating: 0, count: image.height)
        for y in span..<(image.height - span) {
            var sum = 0.0
            for x in 0..<image.width {
                let here = image.luma(x: x, y: y)
                let up = image.luma(x: x, y: y - span)
                let down = image.luma(x: x, y: y + span)
                let ridge = min(up, down) - here
                if ridge > 0 { sum += Double(ridge) }
            }
            profile[y] = sum
        }
        return profile
    }

    // MARK: - Line detection

    /// Grid-line positions from a ridge profile: threshold at a fraction of the
    /// peak, take the weighted centroid of each above-threshold run, then merge
    /// runs closer than a fraction of the median gap (a thick line can split).
    static func detectLines(_ profile: [Double], params: Params) -> [Int] {
        let n = profile.count
        guard n > 0, let maxV = profile.max(), maxV > 0 else { return [] }
        let threshold = maxV * params.lineThresholdFraction

        var lines: [Int] = []
        var x = 0
        while x < n {
            guard profile[x] >= threshold else { x += 1; continue }
            var sumW = 0.0, sumWX = 0.0
            while x < n, profile[x] >= threshold {
                sumW += profile[x]
                sumWX += profile[x] * Double(x)
                x += 1
            }
            lines.append(Int((sumWX / sumW).rounded()))
        }

        guard lines.count > 2 else { return lines }
        // Merge centroids closer than mergeFraction × median gap.
        let minSep = medianGap(lines) * params.mergeFraction
        var merged: [Int] = [lines[0]]
        for p in lines.dropFirst() {
            if Double(p - merged.last!) < minSep {
                merged[merged.count - 1] = (merged.last! + p) / 2
            } else {
                merged.append(p)
            }
        }
        return merged
    }

    // MARK: - Anchor inference

    /// The board index of the fragment's first line on one axis. A clear empty
    /// margin beyond the low (top/left) line ⇒ that's the board edge ⇒ index 0; a
    /// margin beyond the high (bottom/right) line ⇒ the fragment ends at the far
    /// edge ⇒ index N-count. When both or neither side looks like an edge the
    /// fragment is centered. Always clamped so the fragment fits.
    static func anchorIndex(lineCount count: Int, boardSize: Int,
                            loMargin: Int, hiMargin: Int,
                            step: Double, edgeFraction: Double) -> Int {
        let maxAnchor = max(0, boardSize - count)
        let threshold = step * edgeFraction
        let loEdge = Double(loMargin) >= threshold
        let hiEdge = Double(hiMargin) >= threshold

        let anchor: Int
        if loEdge && !hiEdge {
            anchor = 0
        } else if hiEdge && !loEdge {
            anchor = maxAnchor
        } else {
            anchor = maxAnchor / 2
        }
        return min(max(anchor, 0), maxAnchor)
    }

    // MARK: - Helpers

    /// Median of the gaps between consecutive (sorted) line positions.
    static func medianGap(_ lines: [Int]) -> Double {
        guard lines.count >= 2 else { return 0 }
        let gaps = zip(lines, lines.dropFirst()).map { Double($1 - $0) }
        return BoardImageAnalysis.median(gaps)
    }

    /// How regular the line spacing is, mapped to [0, 1]: even spacing (a real
    /// grid) → near 1; ragged spacing → near 0. Used as the fragment confidence.
    static func spacingConfidence(_ lines: [Int]) -> Double {
        guard lines.count >= 3 else { return lines.count == 2 ? 0.5 : 0 }
        let gaps = zip(lines, lines.dropFirst()).map { Double($1 - $0) }
        let mean = gaps.reduce(0, +) / Double(gaps.count)
        guard mean > 0 else { return 0 }
        let variance = gaps.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(gaps.count)
        let cv = variance.squareRoot() / mean          // coefficient of variation
        return max(0, min(1, 1 - cv))
    }
}
