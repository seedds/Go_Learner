//
//  GtpParserTests.swift
//  GoLearnerTests
//
//  Pure-Swift unit tests for the GTP command builder + kata-analyze parser.
//  No engine/CoreML dependency, so they run in the standalone logic bundle.
//

import XCTest
@testable import GoLearner

final class GtpParserTests: XCTestCase {

    // MARK: - GtpCommandBuilder vertex mapping

    func testVertexSkipsColumnI() {
        // Column index 8 must be 'J' (I is skipped in GTP).
        XCTAssertEqual(GtpCommandBuilder.vertex(x: 8, yFromTop: 0, size: 19), "J19")
        XCTAssertEqual(GtpCommandBuilder.vertex(x: 0, yFromTop: 0, size: 19), "A19")
    }

    func testVertexRowIsCountedFromBottom() {
        // Top-left of a 19x19 (yFromTop 0) is row 19; bottom-left is row 1.
        XCTAssertEqual(GtpCommandBuilder.vertex(x: 0, yFromTop: 18, size: 19), "A1")
        // The 3-4 point commonly reported as Q16 = column 15 (Q), row 16.
        XCTAssertEqual(GtpCommandBuilder.vertex(x: 15, yFromTop: 3, size: 19), "Q16")
    }

    func testPlayAndGenmoveCommands() {
        XCTAssertEqual(GtpCommandBuilder.play(color: "B", x: 15, yFromTop: 3, size: 19), "play B Q16")
        XCTAssertEqual(GtpCommandBuilder.play(color: "W", pass: true), "play W pass")
        XCTAssertEqual(GtpCommandBuilder.genmove(color: "B"), "genmove B")
        XCTAssertEqual(GtpCommandBuilder.komi(7.5), "komi 7.5")
        XCTAssertEqual(GtpCommandBuilder.setKoRule("POSITIONAL"), "kata-set-rule ko POSITIONAL")
    }

    // MARK: - vertex → position round-trip

    func testVertexToPositionRoundTrip() {
        let size = 19
        for x in [0, 8, 15, 18] {
            for y in [0, 3, 10, 18] {
                let v = GtpCommandBuilder.vertex(x: x, yFromTop: y, size: size)
                XCTAssertEqual(GtpAnalysisParser.vertexToPosition(v, size: size), y * size + x, "vertex \(v)")
            }
        }
        XCTAssertNil(GtpAnalysisParser.vertexToPosition("pass", size: size))
    }

    // MARK: - Analysis line parsing

    func testParseSingleCandidateAndRootInfo() {
        // A realistic (trimmed) kata-analyze line with one candidate + rootInfo.
        let line = "info move Q16 visits 120 utility 0.1 winrate 0.53 scoreMean 1.2 scoreStdev 12.0 scoreLead 1.5 order 0 pv Q16 D4 rootInfo visits 130 utility 0.1 winrate 0.53 scoreMean 1.2 scoreStdev 12.0 scoreLead 1.5"
        let a = GtpAnalysisParser.parse(line, size: 19)
        XCTAssertNotNil(a)
        XCTAssertEqual(a?.candidates.count, 1)
        let c = a!.candidates[0]
        XCTAssertEqual(c.position, GtpAnalysisParser.vertexToPosition("Q16", size: 19))
        XCTAssertEqual(c.visits, 120)
        XCTAssertEqual(c.winrateWhite, 0.53, accuracy: 1e-5)
        XCTAssertEqual(c.scoreLeadWhite, 1.5, accuracy: 1e-5)
        XCTAssertEqual(a?.rootVisits, 130)
        XCTAssertEqual(a?.rootWinrateWhite ?? 0, 0.53, accuracy: 1e-5)
    }

    func testParseMultipleCandidates() {
        let line = "info move Q16 visits 100 winrate 0.55 scoreLead 2.0 order 0 pv Q16 info move D4 visits 50 winrate 0.52 scoreLead 1.0 order 1 pv D4"
        let a = GtpAnalysisParser.parse(line, size: 19)
        XCTAssertEqual(a?.candidates.count, 2)
        XCTAssertEqual(a?.candidates[0].position, GtpAnalysisParser.vertexToPosition("Q16", size: 19))
        XCTAssertEqual(a?.candidates[1].position, GtpAnalysisParser.vertexToPosition("D4", size: 19))
        XCTAssertEqual(a?.candidates[1].visits, 50)
    }

    func testParsePassCandidate() {
        let line = "info move pass visits 10 winrate 0.4 scoreLead -3.0 order 0 pv pass"
        let a = GtpAnalysisParser.parse(line, size: 19)
        XCTAssertEqual(a?.candidates.count, 1)
        XCTAssertNil(a?.candidates[0].position)
    }

    func testParseOwnershipGridLength() {
        // 9x9 board: 81 ownership floats.
        let owns = (0..<81).map { _ in "0.0" }.joined(separator: " ")
        let line = "info move E5 visits 5 winrate 0.5 scoreLead 0.0 order 0 pv E5 ownership \(owns)"
        let a = GtpAnalysisParser.parse(line, size: 9)
        XCTAssertEqual(a?.ownershipWhite.count, 81)
    }

    func testNonAnalysisLineReturnsNil() {
        XCTAssertNil(GtpAnalysisParser.parse("= Q16", size: 19))
        XCTAssertNil(GtpAnalysisParser.parse("", size: 19))
    }
}
