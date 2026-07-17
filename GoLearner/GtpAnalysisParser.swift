//
//  GtpAnalysisParser.swift
//  GoLearner
//
//  Pure parser for KataGo `kata-analyze` output lines. One analyze report is a
//  single line with one or more `info ...` blocks (candidate moves) optionally
//  followed by `ownership ...` and `rootInfo ...`. Winrate/scoreLead are emitted
//  from White's perspective (the shipped cfg's reportAnalysisWinratesAs=WHITE)
//  and converted to the side-to-move / Black perspective by the caller.
//
//  Kept free of any engine/CoreML dependency so it compiles into the standalone
//  test bundle.
//

import Foundation

/// One candidate move from an analyze report.
struct GtpCandidate: Equatable {
    /// 0-indexed board position, index = yFromTop*size + x. `nil` = pass.
    let position: Int?
    let visits: Int
    /// Win probability, White's perspective (0…1), as emitted by the engine.
    let winrateWhite: Float
    /// Score lead, White's perspective (points).
    let scoreLeadWhite: Float
}

/// Everything parsed from one analyze report.
struct GtpAnalysis: Equatable {
    let candidates: [GtpCandidate]
    /// Ownership grid, White's perspective, length size*size (index yFromTop*size+x),
    /// or empty if the report carried none.
    let ownershipWhite: [Float]
    /// Root search totals, if a `rootInfo` block was present.
    let rootVisits: Int?
    let rootWinrateWhite: Float?
    let rootScoreLeadWhite: Float?
}

enum GtpAnalysisParser {
    /// Parse a `kata-analyze` line for a `size`×`size` board. The engine emits
    /// ownership row-major from the TOP-left in GoLearner's convention already
    /// (KataGo streams rows from y=height-1 down to 0 in board terms, which maps
    /// to top→bottom here); we index it as yFromTop*size + x to match `stones`.
    static func parse(_ line: String, size: Int) -> GtpAnalysis? {
        guard line.contains("info ") || line.contains("ownership ") || line.contains("rootInfo ") else {
            return nil
        }
        let candidates = parseCandidates(line, size: size)
        let ownership = parseOwnership(line, size: size)
        let (rv, rw, rs) = parseRootInfo(line)
        // A report with none of the three payloads is not useful.
        if candidates.isEmpty && ownership.isEmpty && rv == nil { return nil }
        return GtpAnalysis(candidates: candidates,
                           ownershipWhite: ownership,
                           rootVisits: rv,
                           rootWinrateWhite: rw,
                           rootScoreLeadWhite: rs)
    }

    // MARK: - Candidates

    private static func parseCandidates(_ line: String, size: Int) -> [GtpCandidate] {
        // Split on "info " so each chunk is one candidate's fields. The first
        // chunk (before the first "info ") is preamble ("= " etc.).
        let chunks = line.components(separatedBy: "info ")
        guard chunks.count > 1 else { return [] }
        var out: [GtpCandidate] = []
        for chunk in chunks.dropFirst() {
            guard let visits = intField("visits", in: chunk),
                  let winrate = floatField("winrate", in: chunk),
                  let scoreLead = floatField("scoreLead", in: chunk),
                  let moveTok = token(after: "move", in: chunk) else { continue }
            let pos = vertexToPosition(moveTok, size: size)  // nil = pass
            out.append(GtpCandidate(position: pos,
                                    visits: visits,
                                    winrateWhite: winrate,
                                    scoreLeadWhite: scoreLead))
        }
        return out
    }

    // MARK: - Ownership

    private static func parseOwnership(_ line: String, size: Int) -> [Float] {
        // "ownership" appears once, followed by size*size floats. Stop at the
        // next keyword (a non-numeric token) or end of line.
        guard let range = line.range(of: "ownership ") else { return [] }
        let tail = line[range.upperBound...]
        var vals: [Float] = []
        vals.reserveCapacity(size * size)
        for tok in tail.split(separator: " ") {
            if let f = Float(tok) { vals.append(f) } else { break }
            if vals.count == size * size { break }
        }
        return vals.count == size * size ? vals : []
    }

    // MARK: - Root info

    private static func parseRootInfo(_ line: String) -> (Int?, Float?, Float?) {
        guard let range = line.range(of: "rootInfo ") else { return (nil, nil, nil) }
        let chunk = String(line[range.upperBound...])
        return (intField("visits", in: chunk),
                floatField("winrate", in: chunk),
                floatField("scoreLead", in: chunk))
    }

    // MARK: - Field helpers

    /// The whitespace-separated token immediately following `key`.
    private static func token(after key: String, in chunk: String) -> String? {
        let toks = chunk.split(separator: " ")
        guard let i = toks.firstIndex(of: Substring(key)), i + 1 < toks.count else { return nil }
        return String(toks[i + 1])
    }

    private static func intField(_ key: String, in chunk: String) -> Int? {
        token(after: key, in: chunk).flatMap { Int($0) }
    }

    private static func floatField(_ key: String, in chunk: String) -> Float? {
        token(after: key, in: chunk).flatMap { Float($0) }
    }

    /// GTP vertex ("Q16", "pass") → 0-indexed position (yFromTop*size + x), or nil for pass.
    static func vertexToPosition(_ vertex: String, size: Int) -> Int? {
        let v = vertex.uppercased()
        if v == "PASS" { return nil }
        guard let colChar = v.first,
              let colIdx = GtpCommandBuilder.columnLetters.firstIndex(of: colChar),
              let row = Int(v.dropFirst()), row >= 1, row <= size, colIdx < size else {
            return nil
        }
        let x = colIdx
        let yFromTop = size - row
        return yFromTop * size + x
    }
}
