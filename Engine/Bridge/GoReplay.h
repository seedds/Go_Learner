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
@end

/// Pure functions that replay a move list into board positions. No engine, no
/// neural net — just the rules. Thread-safe (each call builds its own Board).
///
/// Every call starts from a *setup base*: pre-placed Black stones
/// (`setupBlack*`) and White stones (`setupWhite*`), with `initialPlayer` the
/// side to move from the base (GoColorBlack/GoColorWhite). A fixed handicap is
/// just black setup stones + White to move; an empty even game passes zero
/// setup stones + Black to move.
@interface GoReplay : NSObject

/// True if the setup base (Black + White stones) is physically placeable under
/// the engine's own rule (`Board::setStonesFailIfNoLibs`): no overlaps and no
/// zero-liberty group. This is exactly what the engine's `loadsgf`/`set_position`
/// require, so validating here keeps the editor's committed position in sync
/// with what the engine will accept (a rejected `loadsgf` would otherwise leave
/// the engine on the old position while the UI shows the new one).
+ (BOOL)isPlaceableSetupWithBoardSize:(int)size
                         setupBlackXs:(const int *_Nullable)sbxs
                         setupBlackYs:(const int *_Nullable)sbys
                      setupBlackCount:(int)setupBlackCount
                         setupWhiteXs:(const int *_Nullable)swxs
                         setupWhiteYs:(const int *_Nullable)swys
                      setupWhiteCount:(int)setupWhiteCount
    NS_SWIFT_NAME(isPlaceableSetup(boardSize:setupBlackXs:setupBlackYs:setupBlackCount:setupWhiteXs:setupWhiteYs:setupWhiteCount:));

/// True if playing `color` at (candX, candY) — or a pass when candX < 0 — is
/// legal after applying the setup base + the given moves. Same rules as engine.
+ (BOOL)isLegalWithBoardSize:(int)size
                setupBlackXs:(const int *_Nullable)sbxs
                setupBlackYs:(const int *_Nullable)sbys
             setupBlackCount:(int)setupBlackCount
                setupWhiteXs:(const int *_Nullable)swxs
                setupWhiteYs:(const int *_Nullable)swys
             setupWhiteCount:(int)setupWhiteCount
               initialPlayer:(int)initialPlayer
                      moveXs:(const int *_Nullable)mxs
                      moveYs:(const int *_Nullable)mys
                  moveColors:(const int *_Nullable)mcolors
                   moveCount:(int)moveCount
                   candidateX:(int)candX
                   candidateY:(int)candY
               candidateColor:(int)candColor
    NS_SWIFT_NAME(isLegal(boardSize:setupBlackXs:setupBlackYs:setupBlackCount:setupWhiteXs:setupWhiteYs:setupWhiteCount:initialPlayer:moveXs:moveYs:moveColors:moveCount:candidateX:candidateY:candidateColor:));

/// Replay the setup base + the given moves onto a fresh `size` board. Setup
/// stones are placed directly (Black then White); pass moves are encoded with
/// x<0. Moves are 0-indexed (x,y) with y from the top. `colors` gives each
/// move's color (GoColorBlack/GoColorWhite), matching `xs`/`ys`. Illegal moves
/// are skipped (best-effort, matching the SGF import path). `plyLimit` < 0
/// replays all moves; otherwise only the first `plyLimit`.
+ (GoPosition *)positionWithBoardSize:(int)size
                        setupBlackXs:(const int *_Nullable)sbxs
                        setupBlackYs:(const int *_Nullable)sbys
                     setupBlackCount:(int)setupBlackCount
                        setupWhiteXs:(const int *_Nullable)swxs
                        setupWhiteYs:(const int *_Nullable)swys
                     setupWhiteCount:(int)setupWhiteCount
                       initialPlayer:(int)initialPlayer
                            moveXs:(const int *_Nullable)mxs
                            moveYs:(const int *_Nullable)mys
                        moveColors:(const int *_Nullable)mcolors
                         moveCount:(int)moveCount
                          plyLimit:(int)plyLimit
    NS_SWIFT_NAME(position(boardSize:setupBlackXs:setupBlackYs:setupBlackCount:setupWhiteXs:setupWhiteYs:setupWhiteCount:initialPlayer:moveXs:moveYs:moveColors:moveCount:plyLimit:));

@end

NS_ASSUME_NONNULL_END
