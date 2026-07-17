//
//  GoBridge.h
//  GoLearner
//
//  Objective-C facing bridge over the vendored KataGo C++ engine subset.
//  Exposes board state, move legality, and neural-network input generation
//  (KataGo's fillRowV7 features) to Swift. No C++ types cross this boundary,
//  so it is safe to import from a pure-Swift bridging header.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Stone / player color, matching KataGo's C_EMPTY / C_BLACK / C_WHITE.
typedef NS_ENUM(int, GoColor) {
    GoColorEmpty = 0,
    GoColorBlack = 1,
    GoColorWhite = 2,
};

/// Shapes of the KataGo v14 (inputs V7) network this bridge feeds.
extern const int GoBridgeNumSpatialFeatures;  // 22
extern const int GoBridgeNumGlobalFeatures;   // 19

/// A stateful wrapper around a single KataGo Board + BoardHistory + Rules.
/// All coordinates are 0-indexed (x from left, y from top).
@interface GoBridge : NSObject

@property (nonatomic, readonly) int boardSize;
@property (nonatomic, readonly) float komi;
/// Ko rule (Rules::KO_*): 0 simple, 1 positional, 2 situational.
@property (nonatomic, readonly) int koRule;
/// Scoring rule (Rules::SCORING_*): 0 area, 1 territory.
@property (nonatomic, readonly) int scoringRule;
/// The side to move (GoColorBlack or GoColorWhite).
@property (nonatomic, readonly) GoColor sideToMove;
/// Number of moves played so far (passes included).
@property (nonatomic, readonly) NSInteger moveCount;
/// Prisoners: opponent stones captured by black / white respectively.
@property (nonatomic, readonly) int blackCaptures;
@property (nonatomic, readonly) int whiteCaptures;
/// True once the game has ended (two consecutive passes under area rules,
/// or a no-result). Playing further moves is the caller's responsibility to prevent.
@property (nonatomic, readonly) BOOL gameFinished;
/// Winner if finished: GoColorBlack/GoColorWhite, or GoColorEmpty for draw/no-result.
@property (nonatomic, readonly) GoColor winner;
/// Final score, White minus Black (komi included). Valid only when gameFinished and not noResult.
@property (nonatomic, readonly) float finalWhiteMinusBlackScore;
/// True if the game ended without a result (e.g. long cycle).
@property (nonatomic, readonly) BOOL isNoResult;

/// Create a fresh game. Uses Tromp-Taylor-ish (area) rules with the given komi,
/// which matches the training rules of the bundled network.
- (instancetype)initWithBoardSize:(int)size komi:(float)komi NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

/// Reset to an empty board of the given size/komi (reuses the instance).
/// Keeps the current ko/scoring rules.
- (void)resetWithBoardSize:(int)size komi:(float)komi;

/// Reset to an empty board with explicit ko/scoring rules (Rules::KO_* /
/// Rules::SCORING_*). Other rule fields keep the Tromp-Taylor-ish defaults.
- (void)resetWithBoardSize:(int)size komi:(float)komi
                   koRule:(int)koRule scoringRule:(int)scoringRule
    NS_SWIFT_NAME(reset(withBoardSize:komi:koRule:scoringRule:));

/// Set up a fixed handicap: place `count` black stones at the given 0-indexed
/// coordinates and make White the side to move. This becomes the game's replay
/// base (undo/snapshot rewind to it, never below), so it must be called right
/// after a reset, before any moves. `xs`/`ys` point to `count` ints each.
/// KataGo infers the handicap count from the board; under the bundled net's
/// WHB_ZERO rules there is no komi bonus to set.
- (void)setupHandicapWithXs:(const int *)xs ys:(const int *)ys count:(int)count
    NS_SWIFT_NAME(setupHandicap(xs:ys:count:));

/// True if placing `color` at (x,y) is legal in the current position.
- (BOOL)isLegalX:(int)x y:(int)y color:(GoColor)color;

/// Attempt to play `color` at (x,y). Returns NO (and does nothing) if illegal.
/// On success, advances the side to move.
- (BOOL)playX:(int)x y:(int)y color:(GoColor)color;

/// Play a pass for `color`. Always legal; advances the side to move.
- (void)passForColor:(GoColor)color;

/// Undo the last move (or pass). Returns NO if there is nothing to undo.
- (BOOL)undo;

/// Deep copy of the current game (board, history, rules, move list).
/// Used by search to explore variations without touching the real game.
- (GoBridge *)clone;

/// A clone of the game rewound to `ply` (0 = empty board, moveCount = current),
/// with only the first `ply` moves applied. `ply` is clamped to [0, moveCount].
/// Used for review/navigation without disturbing the live game.
- (GoBridge *)snapshotAtPly:(NSInteger)ply NS_SWIFT_NAME(snapshot(atPly:));

/// Color at (x,y): empty/black/white.
- (GoColor)stoneColorAtX:(int)x y:(int)y NS_SWIFT_NAME(stoneColor(atX:y:));

/// Fill `spatial` (size = 22*boardSize*boardSize) and `global` (size = 19) with
/// the KataGo V7 neural-net input features for the current position, from the
/// perspective of the current side to move. Buffers must be pre-allocated.
- (void)fillSpatial:(float *)spatial global:(float *)global;

/// The location of the most recent non-pass move, or {-1,-1} if none.
- (void)lastMoveX:(int *)x y:(int *)y;

/// Read the move at history `index` (0-based). Writes the 0-indexed
/// coordinates to x/y and returns YES for a stone move, or NO for a pass
/// (in which case x/y are set to -1). `index` must be in [0, moveCount).
- (BOOL)moveAtIndex:(NSInteger)index outX:(int *)x outY:(int *)y NS_SWIFT_NAME(move(atIndex:outX:outY:));

@end

NS_ASSUME_NONNULL_END
