//
//  GameGIFTests.swift
//  GoLearnerTests
//
//  Covers GIF frame extraction (via the bridge) and the ImageIO encode: frame
//  counts, empty/final positions, capture resolution, and that the written GIF
//  carries the right image count and loop metadata.
//

import XCTest
import ImageIO
import UniformTypeIdentifiers

@MainActor
final class GameGIFTests: XCTestCase {

    private func cell(_ f: GameGIF.Frame, _ x: Int, _ y: Int, size: Int) -> UInt8 {
        f.cells[y * size + x]
    }

    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("gif-test-\(UUID().uuidString).gif")
    }

    /// Thread-safe box so the `@Sendable` progress callback can report back.
    private final class ProgressBox: @unchecked Sendable {
        private let lock = NSLock()
        private var _value = 0.0
        var value: Double { lock.lock(); defer { lock.unlock() }; return _value }
        func set(_ v: Double) { lock.lock(); _value = v; lock.unlock() }
    }

    // MARK: frames(from:)

    func testFrameCountAndEndpoints() {
        let bridge = GoBridge(boardSize: 19, komi: 7.5)
        _ = bridge.playX(3, y: 3, color: .black)
        _ = bridge.playX(15, y: 15, color: .white)

        let frames = GameGIF.frames(from: bridge)
        XCTAssertEqual(frames.count, 3, "empty board + 2 moves")

        // Frame 0 = empty board.
        XCTAssertTrue(frames[0].cells.allSatisfy { $0 == 0 })
        XCTAssertNil(frames[0].lastMove)

        // Final frame matches the live position and last move.
        XCTAssertEqual(cell(frames[2], 3, 3, size: 19), 1)
        XCTAssertEqual(cell(frames[2], 15, 15, size: 19), 2)
        XCTAssertEqual(frames[2].lastMove?.x, 15)
        XCTAssertEqual(frames[2].lastMove?.y, 15)

        // Intermediate frame only has the first stone.
        XCTAssertEqual(cell(frames[1], 3, 3, size: 19), 1)
        XCTAssertEqual(cell(frames[1], 15, 15, size: 19), 0)
    }

    func testFramesResolveCaptures() {
        // White corner captured by Black on the last move.
        let bridge = GoBridge(boardSize: 19, komi: 7.5)
        _ = bridge.playX(1, y: 0, color: .black)
        _ = bridge.playX(0, y: 0, color: .white)
        _ = bridge.playX(0, y: 1, color: .black)

        let frames = GameGIF.frames(from: bridge)
        XCTAssertEqual(frames.count, 4)
        // Before the capture the white stone is present…
        XCTAssertEqual(cell(frames[2], 0, 0, size: 19), 2)
        // …and after Black closes the last liberty it's gone.
        XCTAssertEqual(cell(frames[3], 0, 0, size: 19), 0)
    }

    func testEmptyGameIsSingleFrame() {
        let bridge = GoBridge(boardSize: 9, komi: 7)
        let frames = GameGIF.frames(from: bridge)
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0].cells.count, 9 * 9)
    }

    // MARK: encode

    func testEncodeWritesAllFramesPlusMetadata() throws {
        let bridge = GoBridge(boardSize: 19, komi: 7.5)
        _ = bridge.playX(3, y: 3, color: .black)
        _ = bridge.playX(15, y: 15, color: .white)
        let frames = GameGIF.frames(from: bridge)

        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        var opts = GameGIF.Options()
        opts.pixelSize = .small
        opts.showCoordinates = true
        let progress = ProgressBox()
        try GameGIF.encode(frames, boardSize: 19, options: opts,
                           progress: { progress.set($0) }, to: url)

        XCTAssertEqual(progress.value, 1.0, accuracy: 0.0001)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        let src = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetCount(src), frames.count)
        XCTAssertEqual(CGImageSourceGetType(src) as String?, UTType.gif.identifier)

        // Infinite loop → loop count 0 in the GIF dictionary.
        let props = CGImageSourceCopyProperties(src, nil) as? [CFString: Any]
        let gif = props?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
        XCTAssertEqual(gif?[kCGImagePropertyGIFLoopCount] as? Int, 0)
    }

    func testEncodeNonLoopingSetsLoopCountOne() throws {
        let bridge = GoBridge(boardSize: 9, komi: 7)
        _ = bridge.playX(4, y: 4, color: .black)
        let frames = GameGIF.frames(from: bridge)

        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        var opts = GameGIF.Options()
        opts.loops = false
        try GameGIF.encode(frames, boardSize: 9, options: opts, progress: nil, to: url)

        let src = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let props = CGImageSourceCopyProperties(src, nil) as? [CFString: Any]
        let gif = props?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
        XCTAssertEqual(gif?[kCGImagePropertyGIFLoopCount] as? Int, 1)
    }
}
