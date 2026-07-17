//
//  NNResult.swift
//  GoLearner
//
//  Value types shared by the Core ML model and the search. Kept free of any
//  CoreML dependency so the search + these types can compile into the
//  standalone (hostless) test bundle alongside the C++ bridge.
//

/// Decoded result of one network evaluation, from the perspective of the
/// player to move unless noted otherwise.
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

/// Abstraction over one NN evaluation, so search can be tested with a fake.
/// `Sendable` so it can be held by the `@MainActor` search and its `evaluate`
/// awaited on the `GoEngine` actor without tripping strict concurrency.
protocol PositionEvaluator: Sendable {
    func evaluate(spatial: [Float], global: [Float], legalMask: [Bool], blackToMove: Bool) async throws -> NNResult
}
