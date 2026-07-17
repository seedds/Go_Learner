//
//  NNResult.swift
//  GoLearner
//
//  The analysis view-model the board overlay + win-rate bar render. Populated
//  from the engine's kata-analyze output (see GameState.nnResult(from:)). Kept
//  free of any engine/CoreML dependency so it also compiles into the test bundle.
//

/// Decoded analysis of one position, from the perspective of the player to move
/// unless noted otherwise.
struct NNResult {
    /// Policy probabilities over board positions (index = y*size + x), already
    /// masked to legal moves and normalized. Length = size*size.
    var policy: [Float]
    /// Pass-move probability (same normalization as `policy`).
    var passPolicy: Float
    /// Win probability for the player to move (0...1).
    var winProbToMove: Float
    /// No-result probability (0...1).
    var noResultProb: Float
    /// Expected final score difference from White's perspective (points).
    var whiteScoreMean: Float
    /// Score lead from White's perspective (points), the "fair komi" estimate.
    var whiteLead: Float
    /// Ownership map from White's perspective, tanh'd to [-1, 1]. Length = size*size.
    var whiteOwnership: [Float]
}
