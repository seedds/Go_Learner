//
//  AnalysisOverlay.swift
//  GoLearner
//
//  Draws KataGo analysis over the board: ownership shading and candidate-move
//  markers (top policy moves) with their probabilities.
//

import SwiftUI

struct AnalysisOverlay: View {
    let analysis: NNResult
    let n: Int
    let origin: CGFloat
    let step: CGFloat

    private func point(_ i: Int) -> CGFloat { origin + CGFloat(i) * step }

    var body: some View {
        ZStack(alignment: .topLeading) {
            ownershipLayer
            candidateLayer
        }
    }

    /// Faint black/white squares indicating predicted territory ownership.
    private var ownershipLayer: some View {
        ForEach(0..<(n * n), id: \.self) { idx in
            let own = analysis.whiteOwnership[idx] // +1 = White, -1 = Black
            let x = idx % n, y = idx / n
            Rectangle()
                .fill(own >= 0 ? Color.white : Color.black)
                .opacity(Double(abs(own)) * 0.35)
                .frame(width: step * 0.9, height: step * 0.9)
                .position(x: point(x), y: point(y))
        }
    }

    /// Top few candidate moves, colored by strength.
    private var candidateLayer: some View {
        let top = topMoves(count: 6)
        let best = top.first?.prob ?? 1
        return ForEach(Array(top.enumerated()), id: \.offset) { _, cand in
            let x = cand.pos % n, y = cand.pos / n
            let rel = best > 0 ? cand.prob / best : 0
            ZStack {
                Circle()
                    .fill(candidateColor(rel: rel))
                    .opacity(0.75)
                Text("\(Int((cand.prob * 100).rounded()))")
                    .font(.system(size: step * 0.28, weight: .semibold))
                    .foregroundStyle(.black)
            }
            .frame(width: step * 0.86, height: step * 0.86)
            .position(x: point(x), y: point(y))
        }
    }

    private func candidateColor(rel: Float) -> Color {
        // Green (best) → yellow → orange (weaker).
        let hue = 0.15 + 0.18 * Double(rel) // ~orange to green
        return Color(hue: hue, saturation: 0.85, brightness: 0.95)
    }

    private struct Candidate { let pos: Int; let prob: Float }

    private func topMoves(count: Int) -> [Candidate] {
        analysis.policy.enumerated()
            .map { Candidate(pos: $0.offset, prob: $0.element) }
            .filter { $0.prob > 0.001 }
            .sorted { $0.prob > $1.prob }
            .prefix(count)
            .map { $0 }
    }
}
