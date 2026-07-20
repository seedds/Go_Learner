//
//  HandicapPoints.swift
//  GoLearner
//
//  Fixed (standard) handicap stone placements. Mirrors the engine's
//  `PlayUtils::placeFixedHandicap` (cpp/program/playutils.cpp) point-for-point
//  so the GoReplay-rendered board agrees with the engine's own `fixed_handicap`
//  placement — a mismatch would silently desync the display from the position
//  the engine is actually playing. 0-indexed points (x from left, y from top).
//  Pure Foundation + SGFPoint so it compiles into the hostless test bundle.
//

import Foundation

enum HandicapPoints {
    /// Supported handicap counts for a fixed placement.
    static let range = 2...9

    /// The fixed handicap stones for `count` (2…9) on an `n`×`n` board, or []
    /// if the count/size isn't supported. Placement + constraints mirror the
    /// engine (`placeFixedHandicap`): boards must be ≥7, and counts >4 need an
    /// odd board larger than 7.
    static func fixed(count: Int, boardSize n: Int) -> [SGFPoint] {
        guard n >= 7, range.contains(count) else { return [] }
        if count > 4 && (n % 2 == 0 || n <= 7) { return [] }

        // Corner/side line coordinates, matching the engine exactly:
        //   near = 2 (n≤12) or 3 (n>12);  far = n-1-near;  mid = n/2.
        let near = n <= 12 ? 2 : 3
        let coord = [near, n - 1 - near, n / 2]   // index 0=near, 1=far, 2=mid
        func s(_ xi: Int, _ yi: Int) -> (Int, Int) { (coord[xi], coord[yi]) }

        // Stone set per count, mirroring the engine's switch verbatim.
        let pts: [(Int, Int)]
        switch count {
        case 2: pts = [s(0, 1), s(1, 0)]
        case 3: pts = [s(0, 1), s(1, 0), s(0, 0)]
        case 4: pts = [s(0, 1), s(1, 0), s(0, 0), s(1, 1)]
        case 5: pts = [s(0, 1), s(1, 0), s(0, 0), s(1, 1), s(2, 2)]
        case 6: pts = [s(0, 1), s(1, 0), s(0, 0), s(1, 1), s(0, 2), s(1, 2)]
        case 7: pts = [s(0, 1), s(1, 0), s(0, 0), s(1, 1), s(0, 2), s(1, 2), s(2, 2)]
        case 8: pts = [s(0, 1), s(1, 0), s(0, 0), s(1, 1), s(0, 2), s(1, 2), s(2, 0), s(2, 1)]
        case 9: pts = [s(0, 1), s(1, 0), s(0, 0), s(1, 1), s(0, 2), s(1, 2), s(2, 0), s(2, 1), s(2, 2)]
        default: pts = []
        }
        return pts.map { SGFPoint(x: $0.0, y: $0.1) }
    }
}
