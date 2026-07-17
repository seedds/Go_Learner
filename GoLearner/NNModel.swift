//
//  NNModel.swift
//  GoLearner
//
//  Loads the bundled KataGo Core ML network (18-block b18c384nbt, model
//  version 14 / inputs V7) and runs a single neural-net evaluation on the
//  Neural Engine. Input features come from the C++ bridge (fillRowV7); the
//  raw outputs are decoded here using the exact post-processing math from
//  KataGo's nneval.cpp so the numbers match the reference engine.
//

import CoreML
import Foundation

enum NNModelError: Error {
    case modelNotFound
    case badOutput(String)
}

final class NNModel {
    private let model: MLModel
    private let size: Int

    // KataGo v14 = inputs V7.
    static let numSpatialFeatures = 22
    static let numGlobalFeatures = 19

    // Post-processing constants (KataGo desc.cpp defaults; the Core ML model is
    // converted straight from the checkpoint, so outputScaleMultiplier = 1).
    private let outputScaleMultiplier: Float = 1.0
    private let scoreMeanMultiplier: Float = 20.0
    private let leadMultiplier: Float = 20.0

    /// Loads the compiled model bundled as `KataGoModel19x19fp16.mlmodelc`,
    /// pinned to the CPU + Neural Engine compute units.
    init(size: Int = 19) throws {
        self.size = size
        guard let url = Bundle.main.url(forResource: "KataGoModel19x19fp16", withExtension: "mlmodelc") else {
            throw NNModelError.modelNotFound
        }
        let config = MLModelConfiguration()
        config.computeUnits = .cpuAndNeuralEngine
        self.model = try MLModel(contentsOf: url, configuration: config)
    }

    /// Run one evaluation given pre-filled feature buffers from the bridge.
    /// - Parameters:
    ///   - spatial: 22*size*size floats (channel, y, x) row-major.
    ///   - global: 19 floats.
    ///   - legalMask: size*size+1 bools (board positions then pass); illegal
    ///     positions are excluded from the policy softmax.
    ///   - blackToMove: whether the side to move is Black (for score sign use).
    func evaluate(spatial: [Float], global: [Float], legalMask: [Bool], blackToMove: Bool) throws -> NNResult {
        let area = size * size
        let spatialArray = try MLMultiArray(shape: [1, NSNumber(value: Self.numSpatialFeatures), NSNumber(value: size), NSNumber(value: size)], dataType: .float32)
        let globalArray = try MLMultiArray(shape: [1, NSNumber(value: Self.numGlobalFeatures)], dataType: .float32)

        spatial.withUnsafeBufferPointer { src in
            let dst = spatialArray.dataPointer.bindMemory(to: Float32.self, capacity: src.count)
            dst.update(from: src.baseAddress!, count: src.count)
        }
        global.withUnsafeBufferPointer { src in
            let dst = globalArray.dataPointer.bindMemory(to: Float32.self, capacity: src.count)
            dst.update(from: src.baseAddress!, count: src.count)
        }

        let inputs = try MLDictionaryFeatureProvider(dictionary: [
            "input_spatial": MLFeatureValue(multiArray: spatialArray),
            "input_global": MLFeatureValue(multiArray: globalArray),
        ])
        let out = try model.prediction(from: inputs)

        return try decode(out, area: area, legalMask: legalMask, blackToMove: blackToMove)
    }

    /// Stride (in elements) between consecutive board positions in the policy
    /// output. For a `[1, channels, area+1]` array the last axis is contiguous,
    /// so the stride is 1; we read it from the multi-array to be robust.
    private func policyPositionStride(_ arr: MLMultiArray, area: Int) -> Int {
        // The position axis is the last one whose dimension is area+1.
        let shape = arr.shape.map { $0.intValue }
        let strides = arr.strides.map { $0.intValue }
        if let axis = shape.lastIndex(of: area + 1) {
            return strides[axis]
        }
        return 1
    }

    // MARK: - Decode (mirrors nneval.cpp postprocessing)

    private func decode(_ out: MLFeatureProvider, area: Int, legalMask: [Bool], blackToMove: Bool) throws -> NNResult {
        guard let policyRaw = out.featureValue(for: "output_policy")?.multiArrayValue,
              let valueRaw = out.featureValue(for: "out_value")?.multiArrayValue,
              let miscRaw = out.featureValue(for: "out_miscvalue")?.multiArrayValue,
              let ownRaw = out.featureValue(for: "out_ownership")?.multiArrayValue else {
            throw NNModelError.badOutput("missing output feature")
        }

        // --- Policy: KataGo's optimism policy head emits multiple channels; we
        // use channel 0 (main policy). The flat layout is channel-major
        // ([1, channels, area+1]) so position `pos` maps to `pos * posStride`
        // with channel 0 at offset 0. We derive posStride from the array's
        // shape/strides rather than assuming, so a different export layout
        // still decodes correctly. Board positions are pos in 0..<area, and
        // pos == area is the pass move. ---
        let policyPtr = policyRaw.dataPointer.bindMemory(to: Float32.self, capacity: policyRaw.count)
        let posStride = policyPositionStride(policyRaw, area: area)
        let policyScaling = outputScaleMultiplier // temperature 1.0
        var logits = [Float](repeating: -1e30, count: area + 1)
        var maxLogit: Float = -1e30
        for pos in 0...area {
            if legalMask[pos] {
                let v = policyPtr[pos * posStride] * policyScaling
                logits[pos] = v
                if v > maxLogit { maxLogit = v }
            }
        }
        var sum: Float = 0
        for pos in 0...area where legalMask[pos] {
            let e = expf(logits[pos] - maxLogit)
            logits[pos] = e
            sum += e
        }
        if sum <= 0 { sum = 1 }
        var policy = [Float](repeating: 0, count: area)
        for pos in 0..<area where legalMask[pos] {
            policy[pos] = logits[pos] / sum
        }
        let passPolicy = legalMask[area] ? logits[area] / sum : 0

        // --- Value: softmax over [win, loss, noResult] (player to move). ---
        let valuePtr = valueRaw.dataPointer.bindMemory(to: Float32.self, capacity: valueRaw.count)
        let winL = valuePtr[0] * outputScaleMultiplier
        let lossL = valuePtr[1] * outputScaleMultiplier
        let noResL = valuePtr[2] * outputScaleMultiplier
        let maxV = max(winL, max(lossL, noResL))
        let we = expf(winL - maxV), le = expf(lossL - maxV), ne = expf(noResL - maxV)
        let vsum = we + le + ne
        let winProb = we / vsum
        let noResultProb = ne / vsum

        // --- Score / lead: out_miscvalue[0]=scoreMean, [2]=lead (to-move view). ---
        let miscPtr = miscRaw.dataPointer.bindMemory(to: Float32.self, capacity: miscRaw.count)
        let scoreMeanToMove = miscPtr[0] * outputScaleMultiplier * scoreMeanMultiplier * (1 - noResultProb)
        let leadToMove = miscPtr[2] * outputScaleMultiplier * leadMultiplier * (1 - noResultProb)
        // Flip to White's perspective (network is from the player to move).
        let sign: Float = blackToMove ? -1 : 1
        let whiteScoreMean = sign * scoreMeanToMove
        let whiteLead = sign * leadToMove

        // --- Ownership: tanh(raw), flipped to White's perspective. ---
        let ownPtr = ownRaw.dataPointer.bindMemory(to: Float32.self, capacity: ownRaw.count)
        var ownership = [Float](repeating: 0, count: area)
        for pos in 0..<area {
            let t = tanhf(ownPtr[pos] * outputScaleMultiplier)
            ownership[pos] = sign * t
        }

        return NNResult(
            policy: policy,
            passPolicy: passPolicy,
            winProbToMove: winProb,
            noResultProb: noResultProb,
            whiteScoreMean: whiteScoreMean,
            whiteLead: whiteLead,
            whiteOwnership: ownership
        )
    }
}
