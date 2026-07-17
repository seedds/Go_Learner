//
//  GoEngine.swift
//  GoLearner
//
//  Actor that owns the Core ML network and runs evaluations off the main
//  thread. It deliberately does NOT touch the C++ GoBridge: the caller fills
//  feature buffers on the main actor (microsecond-cheap) and passes plain
//  value types here, so the stateful C++ object stays single-threaded.
//

import Foundation

actor GoEngine {
    private var model: NNModel?
    private let size: Int

    init(size: Int = 19) {
        self.size = size
    }

    /// Lazily load the model on first use. Loading + first prediction is the
    /// slow part, so we keep it inside the actor and off the main thread.
    private func loadedModel() throws -> NNModel {
        if let model { return model }
        let m = try NNModel(size: size)
        model = m
        return m
    }

    /// Evaluate a position from pre-filled feature buffers.
    func evaluate(spatial: [Float], global: [Float], legalMask: [Bool], blackToMove: Bool) async throws -> NNResult {
        let m = try loadedModel()
        return try m.evaluate(spatial: spatial, global: global, legalMask: legalMask, blackToMove: blackToMove)
    }

    /// Warm the model so the first real move isn't blocked on load/compile.
    func warmUp() {
        _ = try? loadedModel()
    }
}

extension GoEngine: PositionEvaluator {}
