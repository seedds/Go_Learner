//
//  BoardRecognizer.swift
//  GoLearner
//
//  The seam between image acquisition (Photos / camera) and the board editor: a
//  recognizer turns a captured image into a RecognizedBoard, which is then
//  handed to the editor for tap-to-correct before committing. Keeping this a
//  protocol lets the acquisition + correction UI (Phase 3) be built and tested
//  against a stub, and the real Vision/Core Image recognizer (Phase 4) drop in
//  without touching the flow.
//

import CoreGraphics
import Foundation

enum BoardRecognitionError: Error, Equatable {
    /// The image couldn't be decoded into pixels.
    case invalidImage
    /// No board could be found / recognized. `reason` is for logging.
    case notRecognized(reason: String)

    /// A single friendly message for a terminal failure.
    var userFacingMessage: String {
        switch self {
        case .invalidImage:
            return "That image couldn't be opened. Try a different photo."
        case .notRecognized:
            return "Couldn't find a Go board. Shoot from directly above with the "
                + "whole board in frame and even lighting — or place the stones by hand."
        }
    }
}

/// Recognizes a Go position from a captured image.
///
/// The target `boardSize` is provided by the caller (a picker in the import UI)
/// rather than inferred: reliably guessing 9 vs 13 vs 19 from an arbitrary photo
/// is the brittle part of recognition, and the user always knows the size. So
/// the recognizer's job is only "read the stones on an N×N grid", and mistakes
/// are corrected in the editor afterward.
protocol BoardRecognizer: Sendable {
    /// Recognize an `boardSize`×`boardSize` position in `image`, optionally
    /// restricted to `cropNormalized` (a [0,1]² top-left-origin rect in the
    /// upright image). Returns a RecognizedBoard or throws.
    func recognize(image: CGImage, boardSize: Int, cropNormalized: CGRect?) async throws -> RecognizedBoard
}

extension BoardRecognizer {
    func recognize(image: CGImage, boardSize: Int) async throws -> RecognizedBoard {
        try await recognize(image: image, boardSize: boardSize, cropNormalized: nil)
    }
}

/// A placeholder recognizer: it finds no stones and returns an empty board, so
/// the acquisition → correct → import flow is fully usable (the user hand-places
/// the position) before the real recognizer lands. Swapping in the Vision
/// recognizer requires no UI change.
struct StubBoardRecognizer: BoardRecognizer {
    func recognize(image: CGImage, boardSize: Int, cropNormalized: CGRect?) async throws -> RecognizedBoard {
        RecognizedBoard(size: boardSize,
                        cells: Array(repeating: .empty, count: boardSize * boardSize),
                        confidence: 0)
    }
}
