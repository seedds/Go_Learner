//
//  AnalysisOverlay.swift
//  GoLearner
//
//  Draws KataGo analysis over the board: ownership shading and candidate-move
//  markers. Each marker shows the move's win rate (%) and visit count, in the
//  LizzieYzy style — best move highlighted, others tinted by relative win rate.
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

    /// Top few candidate moves by visits, each labeled with win rate (%) and
    /// visit count. The most-visited move (the engine's pick) is highlighted;
    /// the rest are tinted by win rate relative to it.
    private var candidateLayer: some View {
        let top = topMoves(count: 6)
        let bestWin = top.first?.winrateToMove ?? 0
        return ForEach(Array(top.enumerated()), id: \.offset) { rank, cand in
            if let pos = cand.position {
                let x = pos % n, y = pos / n
                let rel = bestWin > 0 ? cand.winrateToMove / bestWin : 0
                ZStack {
                    Circle()
                        .fill(candidateColor(rel: rel, isBest: rank == 0))
                        .opacity(0.85)
                    VStack(spacing: 0) {
                        Text("\(Int((cand.winrateToMove * 100).rounded()))")
                            .font(.system(size: step * 0.24, weight: .bold))
                        Text(visitLabel(cand.visits))
                            .font(.system(size: step * 0.18, weight: .regular))
                    }
                    .foregroundStyle(.black)
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
                }
                .frame(width: step * 0.9, height: step * 0.9)
                .position(x: point(x), y: point(y))
            }
        }
    }

    private func candidateColor(rel: Float, isBest: Bool) -> Color {
        if isBest { return Color(hue: 0.33, saturation: 0.85, brightness: 0.95) } // green
        // Weaker moves: yellow → orange as win rate drops relative to the best.
        let hue = 0.08 + 0.12 * Double(max(0, min(1, rel)))
        return Color(hue: hue, saturation: 0.85, brightness: 0.95)
    }

    /// Compact visit count: 120, 1.2k, 12k.
    private func visitLabel(_ v: Int) -> String {
        if v < 1000 { return "\(v)" }
        let k = Double(v) / 1000
        return k < 10 ? String(format: "%.1fk", k) : "\(Int(k.rounded()))k"
    }

    private func topMoves(count: Int) -> [NNResult.Candidate] {
        analysis.candidates
            .filter { $0.position != nil }
            .sorted { $0.visits > $1.visits }
            .prefix(count)
            .map { $0 }
    }
}
