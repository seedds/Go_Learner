//
//  HandicapPoints.swift
//  GoLearner
//
//  Fixed (standard) handicap stone placements. Mirrors the conventional
//  star-point layout used by GTP `fixed_handicap` and common Go servers: the
//  four corners first, then the side midpoints, with tengen (center) added for
//  odd counts. 0-indexed points (x from left, y from top). Pure Foundation +
//  SGFPoint so it compiles into the hostless test bundle.
//
//  Only 19×19 is supported for now (the bundled model's fixed geometry); other
//  sizes return [] until multi-size lands.
//

import Foundation

enum HandicapPoints {
    /// Supported handicap counts for a fixed placement.
    static let range = 2...9

    /// The fixed handicap stones for `count` (2…9) on an `n`×`n` board, or []
    /// if the count/size isn't supported.
    static func fixed(count: Int, boardSize n: Int) -> [SGFPoint] {
        guard n == 19, range.contains(count) else { return [] }
        let e = 3, m = 9, f = 15   // near-corner (line 4), center, far-corner (line 16)

        // The four corners, then the four side midpoints, in GTP order.
        let corners = [(f, e), (e, f), (f, f), (e, e)]
        let sides = [(e, m), (f, m), (m, e), (m, f)]
        let center = (m, m)

        var pts: [(Int, Int)] = []
        switch count {
        case 2: pts = corners.prefix(2).map { $0 }
        case 3: pts = corners.prefix(3).map { $0 }
        case 4: pts = corners
        case 5: pts = corners + [center]
        case 6: pts = corners + Array(sides.prefix(2))
        case 7: pts = corners + Array(sides.prefix(2)) + [center]
        case 8: pts = corners + sides
        case 9: pts = corners + sides + [center]
        default: pts = []
        }
        return pts.map { SGFPoint(x: $0.0, y: $0.1) }
    }
}
