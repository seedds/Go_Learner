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
- (void)resetWithBoardSize:(int)size komi:(float)komi;

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

/// Color at (x,y): empty/black/white.
- (GoColor)stoneColorAtX:(int)x y:(int)y NS_SWIFT_NAME(stoneColor(atX:y:));

/// Fill `spatial` (size = 22*boardSize*boardSize) and `global` (size = 19) with
/// the KataGo V7 neural-net input features for the current position, from the
/// perspective of the current side to move. Buffers must be pre-allocated.
- (void)fillSpatial:(float *)spatial global:(float *)global;

/// The location of the most recent non-pass move, or {-1,-1} if none.
- (void)lastMoveX:(int *)x y:(int *)y;

@end

NS_ASSUME_NONNULL_END
