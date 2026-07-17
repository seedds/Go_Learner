//
//  SGF.swift
//  GoLearner
//
//  A small, self-contained SGF (Smart Game Format) codec for Go games:
//  serialize the current game to text, and parse the main line of an SGF
//  file back into moves. Pure Foundation + the GoColor enum so it compiles
//  into the hostless test bundle alongside the bridge.
//
//  Scope: single game tree, main line only (variations are ignored on import),
//  moves + board size + komi + a few name/result tags. This matches what the
//  app produces and covers the common real-world files. Setup stones (AB/AW)
//  and full property fidelity are out of scope for now.
//

import Foundation

/// One move in an SGF main line. A pass is represented by `x == -1`.
struct SGFMove: Equatable {
    var color: GoColor
    var x: Int
    var y: Int
    var isPass: Bool { x < 0 || y < 0 }

    static func play(_ color: GoColor, _ x: Int, _ y: Int) -> SGFMove { SGFMove(color: color, x: x, y: y) }
    static func pass(_ color: GoColor) -> SGFMove { SGFMove(color: color, x: -1, y: -1) }
}

/// A 0-indexed board point, used for setup stones (SGF `AB`).
struct SGFPoint: Equatable {
    var x: Int
    var y: Int
}

/// A decoded SGF game: enough to reconstruct the board and show metadata.
struct SGFGame: Equatable {
    var boardSize: Int
    var komi: Float
    var moves: [SGFMove]
    /// Handicap count (SGF `HA`), 0 for an even game.
    var handicap: Int
    /// Black setup stones (SGF `AB`), placed before any move. For a fixed
    /// handicap game these are the handicap stones; White then moves first.
    var setupBlack: [SGFPoint]
    var blackName: String?
    var whiteName: String?
    var result: String?

    init(boardSize: Int, komi: Float, moves: [SGFMove],
         handicap: Int = 0, setupBlack: [SGFPoint] = [],
         blackName: String? = nil, whiteName: String? = nil, result: String? = nil) {
        self.boardSize = boardSize
        self.komi = komi
        self.moves = moves
        self.handicap = handicap
        self.setupBlack = setupBlack
        self.blackName = blackName
        self.whiteName = whiteName
        self.result = result
    }
}

enum SGFError: Error, Equatable {
    case noGameTree
    case unsupportedBoardSize(Int)
}

enum SGF {
    private static let letterA = Int(Character("a").asciiValue!)

    // MARK: - Serialize

    static func serialize(_ game: SGFGame) -> String {
        var s = "(;GM[1]FF[4]CA[UTF-8]"
        s += "SZ[\(game.boardSize)]"
        s += "KM[\(formatKomi(game.komi))]"
        s += "RU[Chinese]"
        if game.handicap > 0 { s += "HA[\(game.handicap)]" }
        if !game.setupBlack.isEmpty {
            s += "AB"
            for p in game.setupBlack { s += "[\(encodePoint(p, size: game.boardSize))]" }
        }
        if let pb = game.blackName { s += "PB[\(escape(pb))]" }
        if let pw = game.whiteName { s += "PW[\(escape(pw))]" }
        if let re = game.result { s += "RE[\(escape(re))]" }
        for m in game.moves {
            let tag = m.color == .white ? "W" : "B"
            s += ";\(tag)[\(encodeCoord(m, size: game.boardSize))]"
        }
        s += ")"
        return s
    }

    private static func formatKomi(_ k: Float) -> String {
        // Whole komi as an integer, otherwise one decimal (e.g. 7 or 7.5).
        if k.rounded() == k { return String(Int(k)) }
        return String(format: "%.1f", k)
    }

    private static func encodeCoord(_ m: SGFMove, size: Int) -> String {
        guard !m.isPass else { return "" }
        return encodePoint(SGFPoint(x: m.x, y: m.y), size: size)
    }

    private static func encodePoint(_ p: SGFPoint, size: Int) -> String {
        let cx = Character(UnicodeScalar(letterA + p.x)!)
        let cy = Character(UnicodeScalar(letterA + p.y)!)
        return "\(cx)\(cy)"
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "]", with: "\\]")
    }

    // MARK: - Parse (main line only)

    static func parse(_ text: String) throws -> SGFGame {
        let props = try tokenizeMainLine(text)

        var boardSize = 19
        var komi: Float = 7.5
        var moves: [SGFMove] = []
        var handicap = 0
        var setupBlack: [SGFPoint] = []
        var blackName: String?
        var whiteName: String?
        var result: String?

        for (ident, values) in props {
            let v = values.first ?? ""
            switch ident {
            case "SZ":
                // "19" or "19:19" — take the first component.
                let first = v.split(separator: ":").first.map(String.init) ?? v
                if let n = Int(first.trimmingCharacters(in: .whitespaces)) { boardSize = n }
            case "KM":
                if let k = Float(v.trimmingCharacters(in: .whitespaces)) { komi = k }
            case "HA":
                if let h = Int(v.trimmingCharacters(in: .whitespaces)) { handicap = h }
            case "AB":
                // Black setup stones: one point per bracketed value.
                setupBlack += values.compactMap { decodePoint($0, size: boardSize) }
            case "PB": blackName = unescape(v)
            case "PW": whiteName = unescape(v)
            case "RE": result = unescape(v)
            case "B": moves.append(decodeMove(.black, v, size: boardSize))
            case "W": moves.append(decodeMove(.white, v, size: boardSize))
            default: break
            }
        }
        return SGFGame(boardSize: boardSize, komi: komi, moves: moves,
                       handicap: handicap, setupBlack: setupBlack,
                       blackName: blackName, whiteName: whiteName, result: result)
    }

    /// Decode a single SGF point value (e.g. "dp"), or nil if it's a pass/empty
    /// or off-board. Used for setup-stone (`AB`) values.
    private static func decodePoint(_ v: String, size: Int) -> SGFPoint? {
        let t = v.trimmingCharacters(in: .whitespacesAndNewlines)
        let cs = Array(t)
        guard cs.count >= 2, let ax = cs[0].asciiValue, let ay = cs[1].asciiValue else { return nil }
        let x = Int(ax) - letterA
        let y = Int(ay) - letterA
        guard x >= 0, x < size, y >= 0, y < size else { return nil }
        return SGFPoint(x: x, y: y)
    }

    private static func decodeMove(_ color: GoColor, _ v: String, size: Int) -> SGFMove {
        let t = v.trimmingCharacters(in: .whitespacesAndNewlines)
        // Empty value = pass. "tt" is the legacy pass encoding for boards <= 19.
        if t.isEmpty { return .pass(color) }
        if t == "tt" && size <= 19 { return .pass(color) }
        let cs = Array(t)
        guard cs.count >= 2,
              let ax = cs[0].asciiValue, let ay = cs[1].asciiValue else { return .pass(color) }
        let x = Int(ax) - letterA
        let y = Int(ay) - letterA
        guard x >= 0, x < size, y >= 0, y < size else { return .pass(color) }
        return .play(color, x, y)
    }

    private static func unescape(_ v: String) -> String {
        var out = ""
        var escaped = false
        for c in v {
            if escaped { out.append(c); escaped = false }
            else if c == "\\" { escaped = true }
            else { out.append(c) }
        }
        return out
    }

    /// Walk the SGF text and return `(identifier, [values])` pairs for the main
    /// line only: reading stops at the first variation `(` inside the root, so
    /// nested branches are ignored. Handles `\]`-escaped brackets in values.
    private static func tokenizeMainLine(_ text: String) throws -> [(String, [String])] {
        let chars = Array(text)
        let n = chars.count
        var i = 0
        while i < n && chars[i] != "(" { i += 1 }
        guard i < n else { throw SGFError.noGameTree }
        i += 1  // consume the root '('

        var result: [(String, [String])] = []
        while i < n {
            let c = chars[i]
            if c == "(" { break }          // first variation → end of main line
            if c == ")" { break }          // end of the tree
            if c == ";" || c.isWhitespace { i += 1; continue }

            if c.isLetter {
                // Property identifier: consecutive letters (usually uppercase).
                var ident = ""
                while i < n && chars[i].isLetter {
                    if chars[i].isUppercase { ident.append(chars[i]) }
                    i += 1
                }
                // One or more bracketed values.
                var values: [String] = []
                while i < n {
                    while i < n && chars[i].isWhitespace { i += 1 }
                    guard i < n && chars[i] == "[" else { break }
                    i += 1  // consume '['
                    var value = ""
                    while i < n && chars[i] != "]" {
                        if chars[i] == "\\" && i + 1 < n {
                            value.append(chars[i]); value.append(chars[i + 1]); i += 2
                        } else {
                            value.append(chars[i]); i += 1
                        }
                    }
                    if i < n { i += 1 }  // consume ']'
                    values.append(value)
                }
                if !ident.isEmpty { result.append((ident, values)) }
            } else {
                i += 1
            }
        }
        return result
    }
}
