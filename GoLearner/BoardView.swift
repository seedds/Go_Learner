//
//  BoardView.swift
//  GoLearner
//
//  Renders the goban: wood background, grid, star points, stones, last-move
//  marker, and (optionally) the analysis overlay. Tapping an intersection
//  reports back to GameState.
//

import SwiftUI

struct BoardView: View {
    @Environment(GameState.self) private var game

    var body: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height)
            let n = game.boardSize
            let margin = size / CGFloat(n + 1)
            let step = (size - margin) / CGFloat(n)
            let origin = margin / 2 + step / 2

            ZStack(alignment: .topLeading) {
                boardBackground

                BoardGrid(n: n, origin: origin, step: step)
                    .stroke(Color.black.opacity(0.7), lineWidth: 1)

                starPoints(n: n, origin: origin, step: step)

                if game.analysisEnabled, let analysis = game.analysis {
                    AnalysisOverlay(analysis: analysis, n: n, origin: origin, step: step)
                }

                stones(origin: origin, step: step)

                lastMoveMarker(origin: origin, step: step)
            }
            .frame(width: size, height: size)
            .contentShape(Rectangle())
            .gesture(tapGesture(origin: origin, step: step, boardSize: size))
        }
        .aspectRatio(1, contentMode: .fit)
    }

    private var boardBackground: some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(
                LinearGradient(
                    colors: [Color(red: 0.86, green: 0.68, blue: 0.42),
                             Color(red: 0.80, green: 0.60, blue: 0.34)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
            )
            .shadow(radius: 4)
    }

    private func point(_ i: Int, origin: CGFloat, step: CGFloat) -> CGFloat {
        origin + CGFloat(i) * step
    }

    private func starPoints(n: Int, origin: CGFloat, step: CGFloat) -> some View {
        let coords = starCoordinates(for: n)
        return ForEach(Array(coords.enumerated()), id: \.offset) { _, pt in
            Circle()
                .fill(Color.black.opacity(0.75))
                .frame(width: step * 0.16, height: step * 0.16)
                .position(x: point(pt.0, origin: origin, step: step),
                          y: point(pt.1, origin: origin, step: step))
        }
    }

    private func stones(origin: CGFloat, step: CGFloat) -> some View {
        let n = game.boardSize
        return ForEach(0..<(n * n), id: \.self) { idx in
            let color = game.stones[idx]
            if color != .empty {
                let x = idx % n, y = idx / n
                StoneView(isBlack: color == .black, diameter: step * 0.92)
                    .position(x: point(x, origin: origin, step: step),
                              y: point(y, origin: origin, step: step))
            }
        }
    }

    @ViewBuilder
    private func lastMoveMarker(origin: CGFloat, step: CGFloat) -> some View {
        if let last = game.lastMove {
            let color = game.stones[last.y * game.boardSize + last.x]
            Circle()
                .stroke(color == .black ? Color.white : Color.black, lineWidth: 2)
                .frame(width: step * 0.4, height: step * 0.4)
                .position(x: point(last.x, origin: origin, step: step),
                          y: point(last.y, origin: origin, step: step))
        }
    }

    private func tapGesture(origin: CGFloat, step: CGFloat, boardSize: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onEnded { value in
                let x = Int(((value.location.x - origin) / step).rounded())
                let y = Int(((value.location.y - origin) / step).rounded())
                if x >= 0, x < game.boardSize, y >= 0, y < game.boardSize {
                    game.humanPlay(x: x, y: y)
                }
            }
    }
}

/// A single stone with a subtle 3D highlight.
struct StoneView: View {
    let isBlack: Bool
    let diameter: CGFloat

    var body: some View {
        Circle()
            .fill(
                RadialGradient(
                    colors: isBlack
                        ? [Color(white: 0.35), Color.black]
                        : [Color.white, Color(white: 0.78)],
                    center: .init(x: 0.35, y: 0.35),
                    startRadius: 0.5,
                    endRadius: diameter * 0.7
                )
            )
            .frame(width: diameter, height: diameter)
            .overlay(Circle().stroke(Color.black.opacity(isBlack ? 0.0 : 0.25), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.35), radius: 1, x: 0.5, y: 1)
    }
}

/// The board grid lines.
struct BoardGrid: Shape {
    let n: Int
    let origin: CGFloat
    let step: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let end = origin + CGFloat(n - 1) * step
        for i in 0..<n {
            let p = origin + CGFloat(i) * step
            path.move(to: CGPoint(x: origin, y: p))
            path.addLine(to: CGPoint(x: end, y: p))
            path.move(to: CGPoint(x: p, y: origin))
            path.addLine(to: CGPoint(x: p, y: end))
        }
        return path
    }
}

/// Star-point (hoshi) coordinates for common board sizes.
func starCoordinates(for n: Int) -> [(Int, Int)] {
    let edge: Int
    switch n {
    case 19: edge = 3
    case 13: edge = 3
    case 9: edge = 2
    default: return n >= 7 ? [(n / 2, n / 2)] : []
    }
    let mid = n / 2
    var pts: [(Int, Int)] = []
    let lines = [edge, mid, n - 1 - edge]
    for x in lines {
        for y in lines {
            // On 13x13 skip the mid-edge points to match convention; keep corners+center+sides.
            pts.append((x, y))
        }
    }
    if n == 13 {
        // 13x13 conventionally shows 4 corner hoshi + center only.
        pts = [(edge, edge), (edge, n - 1 - edge), (n - 1 - edge, edge), (n - 1 - edge, n - 1 - edge), (mid, mid)]
    }
    return pts
}
