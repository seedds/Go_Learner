//
//  AIDifficultyTests.swift
//  GoLearnerTests
//
//  Locks the AI thinking-level → per-move time budget mapping. `.standard` must
//  stay at 3s (the app's original device budget) and the cases must be ordered
//  by ascending time so the Settings picker reads low→high.
//

import XCTest
@testable import GoLearner

final class AIDifficultyTests: XCTestCase {

    func testStandardPreservesOriginalDeviceBudget() {
        XCTAssertEqual(AIDifficulty.standard.seconds, 3)
    }

    func testSecondsAreStrictlyAscendingAcrossCases() {
        let secs = AIDifficulty.allCases.map(\.seconds)
        XCTAssertEqual(secs, secs.sorted())
        XCTAssertEqual(Set(secs).count, secs.count, "budgets should be distinct")
    }

    func testEveryBudgetIsPositive() {
        for level in AIDifficulty.allCases {
            XCTAssertGreaterThan(level.seconds, 0, "\(level.label)")
        }
    }

    func testRawValueRoundTrips() {
        for level in AIDifficulty.allCases {
            XCTAssertEqual(AIDifficulty(rawValue: level.rawValue), level)
        }
    }

    func testDetailReadsWholeSecondsWithoutDecimal() {
        XCTAssertEqual(AIDifficulty.standard.detail, "3s per move")
    }
}
