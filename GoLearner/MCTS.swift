//
//  MCTS.swift
//  GoLearner
//
//  Minimal AlphaZero-style PUCT search over GoBridge clones. Runs on the main
//  actor (the bridge is main-actor only); each NN eval is awaited on the
//  GoEngine actor so the main thread is free during inference.
//  Tree values are ALWAYS Black's win probability in [0, 1].
//

import Foundation

struct SearchResult {
    /// Visit-fraction "policy" over board positions (index = y*size + x).
    var policy: [Float]
    /// Visit fraction for the pass move.
    var passPolicy: Float
    /// Best move by visit count; nil means pass.
    var bestMove: Int?
    /// Root value: Black's win probability.
    var blackWinProb: Float
    /// Visit-weighted score lead, White's perspective.
    var whiteLead: Float
    /// Ownership from the root network eval (White's perspective).
    var whiteOwnership: [Float]
    var playouts: Int
}

@MainActor
final class MCTS {
    private final class Node {
        let move: Int            // 0..<area board, area = pass; -1 for root
        let prior: Float
        var visits: Int = 0
        var valueSum: Float = 0  // sum of Black-perspective values
        var children: [Node] = []
        var expanded = false
        var terminalValue: Float? = nil  // Black-perspective, set when game ends here

        init(move: Int, prior: Float) {
            self.move = move
            self.prior = prior
        }
        var meanValue: Float { visits > 0 ? valueSum / Float(visits) : 0.5 }
    }

    private let boardSize: Int
    private let evaluator: PositionEvaluator
    private let cPuct: Float = 1.1
    private let fpuReduction: Float = 0.2

    init(boardSize: Int, evaluator: PositionEvaluator) {
        self.boardSize = boardSize
        self.evaluator = evaluator
    }

    /// Run `playouts` playouts from the position in `rootBridge`.
    /// `shouldContinue` is polled once per playout; return false to stop early
    /// (stale generation / cancelled task). Returns nil only if even the root
    /// evaluation failed or was aborted.
    func search(rootBridge: GoBridge, playouts: Int,
                shouldContinue: () -> Bool) async -> SearchResult? {
        let area = boardSize * boardSize
        let root = Node(move: -1, prior: 1)

        // Playout 0: evaluate + expand the root.
        guard let rootEval = await evaluateAndExpand(node: root, bridge: rootBridge) else { return nil }
        root.visits = 1
        root.valueSum = rootEval.blackValue
        var leadSum: Float = rootEval.whiteLead

        for _ in 1..<max(playouts, 1) {
            if !shouldContinue() || Task.isCancelled { break }

            // Clone the real game and walk down the tree.
            let scratch = rootBridge.clone()
            var path: [Node] = [root]
            var node = root

            while node.expanded && node.terminalValue == nil {
                guard let child = select(parent: node, bridge: scratch) else { break }
                apply(move: child.move, on: scratch)
                path.append(child)
                node = child
            }

            let value: Float
            if let tv = node.terminalValue {
                value = tv
            } else if scratch.gameFinished {
                let tv = terminalBlackValue(scratch)
                node.terminalValue = tv
                value = tv
            } else if let eval = await evaluateAndExpand(node: node, bridge: scratch) {
                value = eval.blackValue
                leadSum += eval.whiteLead
            } else {
                break // engine error; stop searching, return what we have
            }

            for n in path {
                n.visits += 1
                n.valueSum += value
            }
        }

        // Assemble result from root visit counts.
        var policy = [Float](repeating: 0, count: area)
        var passPolicy: Float = 0
        var bestChild: Node? = nil
        let childVisitTotal = root.children.reduce(0) { $0 + $1.visits }
        for child in root.children {
            let frac = childVisitTotal > 0 ? Float(child.visits) / Float(childVisitTotal) : 0
            if child.move == area { passPolicy = frac } else { policy[child.move] = frac }
            if child.visits > (bestChild?.visits ?? 0) { bestChild = child }
        }
        let best = bestChild.map { $0.move }
        return SearchResult(
            policy: policy,
            passPolicy: passPolicy,
            bestMove: (best == area || best == nil) ? nil : best,
            blackWinProb: root.meanValue,
            whiteLead: leadSum / Float(max(root.visits, 1)),
            whiteOwnership: rootEval.ownership,
            playouts: root.visits
        )
    }

    // MARK: - Internals

    /// PUCT child selection. Q is from the perspective of the player to move
    /// at `bridge` (Black-perspective values are flipped for White).
    private func select(parent: Node, bridge: GoBridge) -> Node? {
        let blackToMove = bridge.sideToMove == .black
        let sqrtParent = Float(parent.visits).squareRoot()
        // FPU: unvisited children start slightly below the parent's value.
        let parentQ = qFor(meanBlackValue: parent.meanValue, blackToMove: blackToMove)
        let fpu = max(0, parentQ - fpuReduction)

        var best: Node? = nil
        var bestScore: Float = -.infinity
        for child in parent.children {
            let q = child.visits > 0
                ? qFor(meanBlackValue: child.meanValue, blackToMove: blackToMove)
                : fpu
            let u = cPuct * child.prior * sqrtParent / Float(1 + child.visits)
            let s = q + u
            if s > bestScore { bestScore = s; best = child }
        }
        return best
    }

    private func qFor(meanBlackValue v: Float, blackToMove: Bool) -> Float {
        blackToMove ? v : 1 - v
    }

    private func apply(move: Int, on bridge: GoBridge) {
        let area = boardSize * boardSize
        let color = bridge.sideToMove
        if move == area {
            bridge.pass(for: color)
        } else {
            let x = move % boardSize, y = move / boardSize
            if !bridge.playX(Int32(x), y: Int32(y), color: color) {
                bridge.pass(for: color) // stale-legality fallback; should not happen
            }
        }
    }

    /// Real game result → Black-perspective value.
    private func terminalBlackValue(_ bridge: GoBridge) -> Float {
        if bridge.isNoResult { return 0.5 }
        switch bridge.winner {
        case .black: return 1
        case .white: return 0
        default: return 0.5
        }
    }

    private struct LeafEval {
        var blackValue: Float
        var whiteLead: Float
        var ownership: [Float]
    }

    /// Evaluate the position in `bridge` with the NN and expand `node`'s
    /// children over all legal moves (priors from the masked policy).
    private func evaluateAndExpand(node: Node, bridge: GoBridge) async -> LeafEval? {
        let area = boardSize * boardSize
        var spatial = [Float](repeating: 0, count: Int(GoBridgeNumSpatialFeatures) * area)
        var global = [Float](repeating: 0, count: Int(GoBridgeNumGlobalFeatures))
        spatial.withUnsafeMutableBufferPointer { sp in
            global.withUnsafeMutableBufferPointer { gp in
                bridge.fillSpatial(sp.baseAddress!, global: gp.baseAddress!)
            }
        }
        let side = bridge.sideToMove
        var legalMask = [Bool](repeating: false, count: area + 1)
        for y in 0..<boardSize {
            for x in 0..<boardSize {
                legalMask[y * boardSize + x] = bridge.isLegalX(Int32(x), y: Int32(y), color: side)
            }
        }
        legalMask[area] = true
        let blackToMove = side == .black

        guard let r = try? await evaluator.evaluate(
            spatial: spatial, global: global, legalMask: legalMask, blackToMove: blackToMove
        ) else { return nil }

        if !node.expanded {
            for pos in 0..<area where legalMask[pos] && r.policy[pos] > 0 {
                node.children.append(Node(move: pos, prior: r.policy[pos]))
            }
            node.children.append(Node(move: area, prior: r.passPolicy))
            node.expanded = true
        }

        // NNResult.winProbToMove is for the player to move; convert to Black.
        // Treat no-result as half a point for each side.
        let blackValue: Float = blackToMove
            ? r.winProbToMove + 0.5 * r.noResultProb
            : 1 - r.winProbToMove - 0.5 * r.noResultProb
        return LeafEval(blackValue: blackValue, whiteLead: r.whiteLead, ownership: r.whiteOwnership)
    }
}
