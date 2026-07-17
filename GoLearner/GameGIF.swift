//
//  GameGIF.swift
//  GoLearner
//
//  Renders a game to an animated GIF: one frame per ply (plus the empty board),
//  drawn with CoreGraphics and streamed into an ImageIO destination so memory
//  stays flat for long games. Pure Foundation/CoreGraphics/ImageIO/CoreText +
//  GoColor — no SwiftUI or CoreML — so it also compiles into the hostless test
//  bundle and the encode step runs off the main actor.
//
//  Frames come from GoReplay's stateless replay (GameState.gifFrames), so this
//  never touches the single per-process GTP engine.
//

import Foundation
import CoreGraphics
import ImageIO
import CoreText
import UniformTypeIdentifiers

enum GameGIF {

    // MARK: - Value types

    /// One rendered position. `cells` is a flat board (index = y*size + x) with
    /// 0 empty / 1 black / 2 white — matching GoColor's raw values but kept as
    /// plain bytes so a Frame is trivially Sendable across the encode task.
    struct Frame: Sendable, Equatable {
        var cells: [UInt8]
        var lastMove: (x: Int, y: Int)?

        static func == (a: Frame, b: Frame) -> Bool {
            a.cells == b.cells && a.lastMove?.x == b.lastMove?.x && a.lastMove?.y == b.lastMove?.y
        }
    }

    /// Output board size in pixels (the square wood area including label bands).
    enum PixelSize: Int, CaseIterable, Identifiable, Sendable {
        case small = 320, medium = 540, large = 720
        var id: Int { rawValue }
        var label: String {
            switch self {
            case .small: return "Small"
            case .medium: return "Medium"
            case .large: return "Large"
            }
        }
    }

    struct Options: Sendable {
        /// Seconds each move is held on screen.
        var moveDelay: Double = 0.8
        var pixelSize: PixelSize = .medium
        /// Loop forever when true; play once when false.
        var loops: Bool = true
        /// Extra seconds the final position is held (added to the last frame).
        var finalHold: Double = 2.0
        /// Draw A–T column letters and row numbers around the board.
        var showCoordinates: Bool = false
    }

    enum GIFError: Error { case contextFailed, destinationFailed, finalizeFailed }

    // MARK: - Frame extraction (stateless replay via GoReplay)

    /// Snapshot every position (base → final move) as GIF frames, by replaying
    /// `moves` (after `handicap`) with KataGo's rules. Returns `moves.count + 1`
    /// frames. Engine-free and thread-safe.
    static func frames(size: Int, handicap: [SGFPoint], moves: [ReplayMove]) -> [Frame] {
        var out: [Frame] = []
        out.reserveCapacity(moves.count + 1)
        for ply in 0...moves.count {
            let pos = GoReplayKit.position(size: size, handicap: handicap, moves: moves, plyLimit: ply)
            let last: (x: Int, y: Int)? = pos.lastMoveX >= 0 ? (Int(pos.lastMoveX), Int(pos.lastMoveY)) : nil
            out.append(Frame(cells: [UInt8](pos.cells), lastMove: last))
        }
        return out
    }

    // MARK: - Encode (off-main: pure CoreGraphics/ImageIO)

    /// Encode `frames` to an animated GIF at `url`. `progress` is called with a
    /// 0…1 fraction after each frame is written.
    nonisolated static func encode(_ frames: [Frame], boardSize n: Int, options: Options,
                                   progress: (@Sendable (Double) -> Void)? = nil,
                                   to url: URL) throws {
        guard !frames.isEmpty else { throw GIFError.contextFailed }
        let count = frames.count

        let fileProps: [CFString: Any] = [
            kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFLoopCount: options.loops ? 0 : 1  // 0 = infinite
            ]
        ]
        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.gif.identifier as CFString, count, nil) else {
            throw GIFError.destinationFailed
        }
        CGImageDestinationSetProperties(dest, fileProps as CFDictionary)

        for (i, frame) in frames.enumerated() {
            guard let image = renderCGImage(frame, boardSize: n, options: options) else {
                throw GIFError.contextFailed
            }
            let isLast = i == count - 1
            let delay = options.moveDelay + (isLast ? options.finalHold : 0)
            let frameProps: [CFString: Any] = [
                kCGImagePropertyGIFDictionary: [
                    kCGImagePropertyGIFDelayTime: delay,
                    kCGImagePropertyGIFUnclampedDelayTime: delay
                ]
            ]
            CGImageDestinationAddImage(dest, image, frameProps as CFDictionary)
            progress?(Double(i + 1) / Double(count))
        }

        guard CGImageDestinationFinalize(dest) else { throw GIFError.finalizeFailed }
    }

    // MARK: - Drawing

    private static let rgb = CGColorSpaceCreateDeviceRGB()
    private static func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
        CGColor(colorSpace: rgb, components: [r, g, b, a])!
    }

    private static func renderCGImage(_ frame: Frame, boardSize n: Int, options: Options) -> CGImage? {
        let px = options.pixelSize.rawValue
        guard let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: rgb,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }
        let H = CGFloat(px)
        let band = options.showCoordinates ? H * 0.055 : 0
        let area = H - 2 * band
        let margin = area / CGFloat(n + 1)
        let step = (area - margin) / CGFloat(n)
        let orig = band + margin / 2 + step / 2   // center of the first line

        // pixel helpers: board arrays use y-down; CGContext is y-up.
        func xpos(_ col: Int) -> CGFloat { orig + CGFloat(col) * step }
        func ypos(_ row: Int) -> CGFloat { H - (orig + CGFloat(row) * step) }

        // Wood background.
        ctx.setFillColor(color(0.84, 0.66, 0.40))
        ctx.fill(CGRect(x: 0, y: 0, width: H, height: H))

        // Grid.
        ctx.setStrokeColor(color(0, 0, 0, 0.7))
        ctx.setLineWidth(max(1, step * 0.03))
        let lo = orig, hi = orig + CGFloat(n - 1) * step
        for i in 0..<n {
            let p = orig + CGFloat(i) * step
            ctx.move(to: CGPoint(x: lo, y: H - p));   ctx.addLine(to: CGPoint(x: hi, y: H - p))
            ctx.move(to: CGPoint(x: p, y: H - lo));   ctx.addLine(to: CGPoint(x: p, y: H - hi))
        }
        ctx.strokePath()

        // Star points.
        ctx.setFillColor(color(0, 0, 0, 0.75))
        let hoshiR = step * 0.09
        for (hx, hy) in hoshi(n) {
            ctx.fillEllipse(in: CGRect(x: xpos(hx) - hoshiR, y: ypos(hy) - hoshiR,
                                       width: hoshiR * 2, height: hoshiR * 2))
        }

        // Stones.
        let r = step * 0.46
        for idx in 0..<(n * n) where frame.cells[idx] != 0 {
            let isBlack = frame.cells[idx] == 1
            let cx = xpos(idx % n), cy = ypos(idx / n)
            let rect = CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2)
            ctx.setFillColor(isBlack ? color(0.06, 0.06, 0.06) : color(0.97, 0.97, 0.97))
            ctx.fillEllipse(in: rect)
            if !isBlack {
                ctx.setStrokeColor(color(0, 0, 0, 0.25))
                ctx.setLineWidth(max(0.5, step * 0.02))
                ctx.strokeEllipse(in: rect.insetBy(dx: 0.5, dy: 0.5))
            }
        }

        // Last-move marker.
        if let last = frame.lastMove {
            let idx = last.y * n + last.x
            let onBlack = idx >= 0 && idx < frame.cells.count && frame.cells[idx] == 1
            ctx.setStrokeColor(onBlack ? color(1, 1, 1) : color(0, 0, 0))
            ctx.setLineWidth(max(1, step * 0.06))
            let mr = step * 0.2
            ctx.strokeEllipse(in: CGRect(x: xpos(last.x) - mr, y: ypos(last.y) - mr,
                                         width: mr * 2, height: mr * 2))
        }

        if options.showCoordinates {
            drawCoordinates(ctx, n: n, band: band, fontSize: band * 0.62,
                            xpos: xpos, ypos: ypos)
        }

        return ctx.makeImage()
    }

    /// KataGo/Go column letters skip "I".
    private static let columnLetters = Array("ABCDEFGHJKLMNOPQRSTUVWXYZ")

    private static func drawCoordinates(_ ctx: CGContext, n: Int, band: CGFloat, fontSize: CGFloat,
                                        xpos: (Int) -> CGFloat, ypos: (Int) -> CGFloat) {
        let font = CTFontCreateWithName("HelveticaNeue" as CFString, fontSize, nil)
        let ink = color(0, 0, 0, 0.75)
        for col in 0..<n where col < columnLetters.count {
            drawCentered(ctx, String(columnLetters[col]), font: font, ink: ink,
                         center: CGPoint(x: xpos(col), y: band / 2))
        }
        for row in 0..<n {
            // Top row (y=0) is numbered n; bottom row (y=n-1) is 1.
            drawCentered(ctx, String(n - row), font: font, ink: ink,
                         center: CGPoint(x: band / 2, y: ypos(row)))
        }
    }

    private static func drawCentered(_ ctx: CGContext, _ s: String, font: CTFont, ink: CGColor,
                                     center: CGPoint) {
        let attrs: [NSAttributedString.Key: Any] = [
            .init(kCTFontAttributeName as String): font,
            .init(kCTForegroundColorAttributeName as String): ink,
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: attrs))
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
        ctx.textMatrix = .identity
        ctx.textPosition = CGPoint(x: center.x - width / 2, y: center.y - (ascent - descent) / 2)
        CTLineDraw(line, ctx)
    }

    /// Star-point (hoshi) coordinates for the common board sizes.
    private static func hoshi(_ n: Int) -> [(Int, Int)] {
        switch n {
        case 19: let e = 3, m = 9; return cross(e, m, n)
        case 13: let e = 3, m = 6; return [(e, e), (e, n - 1 - e), (n - 1 - e, e), (n - 1 - e, n - 1 - e), (m, m)]
        case 9:  let e = 2, m = 4; return [(e, e), (e, n - 1 - e), (n - 1 - e, e), (n - 1 - e, n - 1 - e), (m, m)]
        default: return n >= 7 ? [(n / 2, n / 2)] : []
        }
    }

    private static func cross(_ e: Int, _ m: Int, _ n: Int) -> [(Int, Int)] {
        let lines = [e, m, n - 1 - e]
        var pts: [(Int, Int)] = []
        for x in lines { for y in lines { pts.append((x, y)) } }
        return pts
    }
}
