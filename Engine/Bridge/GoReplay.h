//
//  GoReplay.h
//  GoLearner
//
//  Stateless board reconstruction over the vendored KataGo rules (game/board.cpp
//  + boardhistory.cpp), independent of the GTP engine. Given a move list it
//  replays with KataGo's own capture/ko rules and returns the resulting stone
//  grid — used for rendering the live position, review navigation, GIF frames,
//  and library thumbnails without touching (or needing) the single per-process
//  engine. All coordinates are 0-indexed (x from left, y from top).
//

#import <Foundation/Foundation.h>
#import "GoTypes.h"

NS_ASSUME_NONNULL_BEGIN

/// One replayed position: the stone grid (row-major, index = y*size + x) plus
/// the vertex of the last non-pass move (or {-1,-1}).
@interface GoPosition : NSObject
@property (nonatomic, readonly) int size;
/// `size*size` bytes: 0 empty / 1 black / 2 white (GoColor raw values).
@property (nonatomic, readonly) NSData *cells;
@property (nonatomic, readonly) int lastMoveX;
@property (nonatomic, readonly) int lastMoveY;
@property (nonatomic, readonly) int blackCaptures;
@property (nonatomic, readonly) int whiteCaptures;
- (GoColor)colorAtX:(int)x y:(int)y NS_SWIFT_NAME(color(atX:y:));
@end

/// Pure functions that replay a move list into board positions. No engine, no
/// neural net — just the rules. Thread-safe (each call builds its own Board).
@interface GoReplay : NSObject

/// True if playing `color` at (candX, candY) — or a pass when candX < 0 — is
/// legal after replaying `handicap` + the given moves. Same rules as the engine.
+ (BOOL)isLegalWithBoardSize:(int)size
                  handicapXs:(const int *_Nullable)hxs
                  handicapYs:(const int *_Nullable)hys
               handicapCount:(int)handicapCount
                      moveXs:(const int *_Nullable)mxs
                      moveYs:(const int *_Nullable)mys
                  moveColors:(const int *_Nullable)mcolors
                   moveCount:(int)moveCount
                   candidateX:(int)candX
                   candidateY:(int)candY
               candidateColor:(int)candColor
    NS_SWIFT_NAME(isLegal(boardSize:handicapXs:handicapYs:handicapCount:moveXs:moveYs:moveColors:moveCount:candidateX:candidateY:candidateColor:));

/// Replay `count` handicap stones + the given moves onto a fresh `size` board.
/// Handicap points are placed as Black (White then moves first); pass moves are
/// encoded with x<0. Moves are 0-indexed (x,y) with y from the top. `colors`
/// gives each move's color (GoColorBlack/GoColorWhite), matching `xs`/`ys`.
/// Illegal moves are skipped (best-effort, matching the SGF import path).
/// `plyLimit` < 0 replays all moves; otherwise only the first `plyLimit`.
+ (GoPosition *)positionWithBoardSize:(int)size
                        handicapXs:(const int *_Nullable)hxs
                        handicapYs:(const int *_Nullable)hys
                     handicapCount:(int)handicapCount
                            moveXs:(const int *_Nullable)mxs
                            moveYs:(const int *_Nullable)mys
                        moveColors:(const int *_Nullable)mcolors
                         moveCount:(int)moveCount
                          plyLimit:(int)plyLimit
    NS_SWIFT_NAME(position(boardSize:handicapXs:handicapYs:handicapCount:moveXs:moveYs:moveColors:moveCount:plyLimit:));

@end

NS_ASSUME_NONNULL_END
