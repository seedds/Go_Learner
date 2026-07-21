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
    /// Candidate moves the engine searched, ordered as the engine reported them
    /// (best first). Drives the on-board winrate/visits markers.
    var candidates: [Candidate]
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

    /// One searched move, converted to the side-to-move perspective the board
    /// renders. Mirrors LizzieYzy's per-move winrate + visit display.
    struct Candidate: Equatable {
        /// 0-indexed board position (index = y*size + x), or nil for pass.
        let position: Int?
        /// Win probability for the side to move if this move is played (0...1).
        let winrateToMove: Float
        /// Search visits spent on this move.
        let visits: Int
    }

    /// Map parsed analyze candidates onto the side-to-move perspective. Engine
    /// winrate is White's (shipped cfg's reportAnalysisWinratesAs=WHITE), so
    /// flip it for Black to move — the same convention `GameState` uses for the
    /// root winrate. Pure/engine-free so it unit-tests in the host bundle.
    static func candidates(from parsed: [GtpCandidate], blackToMove: Bool) -> [Candidate] {
        parsed.map { c in
            Candidate(position: c.position,
                      winrateToMove: blackToMove ? 1 - c.winrateWhite : c.winrateWhite,
                      visits: c.visits)
        }
    }
}
