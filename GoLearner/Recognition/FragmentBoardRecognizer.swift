//
//  FragmentBoardRecognizer.swift
//  GoLearner
//
//  The partial-board counterpart to VisionBoardRecognizer: read a cropped
//  fragment of a board (a corner/edge tesuji diagram) and return a
//  RecognizedFragment positioned on the full board. It reuses CIImagePrep for
//  crop + grayscale but skips full-board quad/perspective detection — a fragment
//  has no complete board rectangle to find, and the user frames it straight-on
//  with the crop rectangle. The pure FragmentAnalysis does the grid-line
//  detection, classification, and anchor inference; the user corrects the result
//  in the board editor.
//

import CoreImage
import CoreGraphics
import Foundation

struct FragmentBoardRecognizer {
    /// Side length of the square grayscale buffer sampled for detection.
    var sampledSize = 720
    var params = FragmentAnalysis.Params()

    private let prep = CIImagePrep()

    /// Recognize a fragment inside `cropNormalized` (a [0,1]² top-left-origin rect
    /// in the upright image) on a full `boardSize` board. Throws
    /// `BoardRecognitionError` on undecodable input or when no grid is found.
    func recognize(image: CGImage, boardSize: Int, cropNormalized: CGRect) async throws -> RecognizedFragment {
        let ci = CIImage(cgImage: image)
        let cropped = prep.crop(ci, normalized: cropNormalized)

        guard let gray = prep.grayscaleBuffer(cropped, side: sampledSize) else {
            throw BoardRecognitionError.invalidImage
        }

        let fragment = FragmentAnalysis.analyze(gray, boardSize: boardSize, params: params)
        guard fragment.rows >= 1, fragment.cols >= 1 else {
            throw BoardRecognitionError.notRecognized(reason: "no grid lines detected in the cropped region")
        }
        return fragment
    }
}
