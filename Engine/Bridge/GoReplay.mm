//
//  GoReplay.mm
//  GoLearner
//
//  ObjC++ implementation of the stateless replay bridge over KataGo's rules.
//

#import "GoReplay.h"

#include <vector>
#include "board.h"
#include "boardhistory.h"
#include "rules.h"

namespace {
// Board::initHash() guards with std::call_once internally, so it is safe to call
// from here even though the GTP engine also calls it. ScoreValue tables are NOT
// needed for pure replay (only scoring/NN features use them), so we don't touch
// them — that avoids the single-init assertion clashing with the engine.
void ensureHashInit() {
    static std::once_flag flag;
    std::call_once(flag, []() { Board::initHash(); });
}
}

@implementation GoPosition {
    int _size;
    NSData *_cells;
    int _lastX;
    int _lastY;
    int _blackCaptures;
    int _whiteCaptures;
}

- (instancetype)initWithSize:(int)size
                       cells:(NSData *)cells
                       lastX:(int)lastX
                       lastY:(int)lastY
               blackCaptures:(int)blackCaptures
               whiteCaptures:(int)whiteCaptures {
    if ((self = [super init])) {
        _size = size;
        _cells = cells;
        _lastX = lastX;
        _lastY = lastY;
        _blackCaptures = blackCaptures;
        _whiteCaptures = whiteCaptures;
    }
    return self;
}

- (int)size { return _size; }
- (NSData *)cells { return _cells; }
- (int)lastMoveX { return _lastX; }
- (int)lastMoveY { return _lastY; }
- (int)blackCaptures { return _blackCaptures; }
- (int)whiteCaptures { return _whiteCaptures; }

@end

// Place the setup base (Black stones, then White stones) and set the side to
// move. Shared by position building and legality checks so both agree on the
// base. `initialPlayer` is GoColorBlack/GoColorWhite (defaulting to Black when
// unset/empty). Returns the initial player actually used.
static Player applySetup(Board &board, BoardHistory &history, int size, Rules rules,
                         const int *sbxs, const int *sbys, int setupBlackCount,
                         const int *swxs, const int *swys, int setupWhiteCount,
                         int initialPlayer) {
    if (sbxs && sbys) {
        for (int i = 0; i < setupBlackCount; i++)
            board.setStone(Location::getLoc(sbxs[i], sbys[i], size), C_BLACK);
    }
    if (swxs && swys) {
        for (int i = 0; i < setupWhiteCount; i++)
            board.setStone(Location::getLoc(swxs[i], swys[i], size), C_WHITE);
    }
    Player initialPla = (initialPlayer == GoColorWhite) ? P_WHITE : P_BLACK;
    history.clear(board, initialPla, rules, 0);
    return initialPla;
}

// Apply the setup base + the first `limit` moves into `board`/`history`, leaving
// `pla` as the side to move. Shared by position building and legality checks.
static Player replayInto(Board &board, BoardHistory &history, int size,
                         const int *sbxs, const int *sbys, int setupBlackCount,
                         const int *swxs, const int *swys, int setupWhiteCount,
                         int initialPlayer,
                         const int *mxs, const int *mys, const int *mcolors,
                         int moveCount, int limit) {
    Rules rules = Rules::getTrompTaylorish();
    Player pla = applySetup(board, history, size, rules,
                            sbxs, sbys, setupBlackCount, swxs, swys, setupWhiteCount,
                            initialPlayer);
    int n = (limit < 0 || limit > moveCount) ? moveCount : limit;
    for (int i = 0; i < n; i++) {
        Player movePla = mcolors ? ((mcolors[i] == GoColorWhite) ? P_WHITE : P_BLACK) : pla;
        bool isPass = (mxs == nullptr) || (mxs[i] < 0);
        Loc loc = isPass ? Board::PASS_LOC : Location::getLoc(mxs[i], mys[i], size);
        if (!isPass && !history.isLegal(board, loc, movePla)) {
            pla = getOpp(movePla);
            continue;
        }
        history.makeBoardMoveAssumeLegal(board, loc, movePla, NULL);
        pla = getOpp(movePla);
    }
    return pla;
}

@implementation GoReplay

+ (BOOL)isPlaceableSetupWithBoardSize:(int)size
                         setupBlackXs:(const int *)sbxs
                         setupBlackYs:(const int *)sbys
                      setupBlackCount:(int)setupBlackCount
                         setupWhiteXs:(const int *)swxs
                         setupWhiteYs:(const int *)swys
                      setupWhiteCount:(int)setupWhiteCount {
    ensureHashInit();
    Board board(size, size);
    std::vector<Move> placements;
    if (sbxs && sbys)
        for (int i = 0; i < setupBlackCount; i++)
            placements.emplace_back(Location::getLoc(sbxs[i], sbys[i], size), P_BLACK);
    if (swxs && swys)
        for (int i = 0; i < setupWhiteCount; i++)
            placements.emplace_back(Location::getLoc(swxs[i], swys[i], size), P_WHITE);
    // Same check the engine's set_position / loadsgf use: overlaps or zero-liberty
    // groups fail. On a fresh board an empty placement list is trivially valid.
    return board.setStonesFailIfNoLibs(placements) ? YES : NO;
}

+ (BOOL)isLegalWithBoardSize:(int)size
                setupBlackXs:(const int *)sbxs
                setupBlackYs:(const int *)sbys
             setupBlackCount:(int)setupBlackCount
                setupWhiteXs:(const int *)swxs
                setupWhiteYs:(const int *)swys
             setupWhiteCount:(int)setupWhiteCount
               initialPlayer:(int)initialPlayer
                      moveXs:(const int *)mxs
                      moveYs:(const int *)mys
                  moveColors:(const int *)mcolors
                   moveCount:(int)moveCount
                   candidateX:(int)candX
                   candidateY:(int)candY
               candidateColor:(int)candColor {
    ensureHashInit();
    Board board(size, size);
    BoardHistory history;
    replayInto(board, history, size, sbxs, sbys, setupBlackCount, swxs, swys, setupWhiteCount,
               initialPlayer, mxs, mys, mcolors, moveCount, -1);
    Player pla = (candColor == GoColorWhite) ? P_WHITE : P_BLACK;
    if (candX < 0) return YES;   // pass is always legal
    Loc loc = Location::getLoc(candX, candY, size);
    return history.isLegal(board, loc, pla) ? YES : NO;
}

+ (GoPosition *)positionWithBoardSize:(int)size
                        setupBlackXs:(const int *)sbxs
                        setupBlackYs:(const int *)sbys
                     setupBlackCount:(int)setupBlackCount
                        setupWhiteXs:(const int *)swxs
                        setupWhiteYs:(const int *)swys
                     setupWhiteCount:(int)setupWhiteCount
                       initialPlayer:(int)initialPlayer
                            moveXs:(const int *)mxs
                            moveYs:(const int *)mys
                        moveColors:(const int *)mcolors
                         moveCount:(int)moveCount
                          plyLimit:(int)plyLimit {
    ensureHashInit();

    Rules rules = Rules::getTrompTaylorish();
    Board board(size, size);
    BoardHistory history;
    // Setup base: place Black then White stones, set the side to move.
    Player pla = applySetup(board, history, size, rules,
                            sbxs, sbys, setupBlackCount, swxs, swys, setupWhiteCount,
                            initialPlayer);

    int lastX = -1, lastY = -1;
    int limit = (plyLimit < 0 || plyLimit > moveCount) ? moveCount : plyLimit;
    for (int i = 0; i < limit; i++) {
        Player movePla = pla;
        if (mcolors) {
            movePla = (mcolors[i] == GoColorWhite) ? P_WHITE : P_BLACK;
        }
        bool isPass = (mxs == nullptr) || (mxs[i] < 0);
        Loc loc = isPass ? Board::PASS_LOC : Location::getLoc(mxs[i], mys[i], size);
        if (!isPass && !history.isLegal(board, loc, movePla)) {
            // Skip illegal move but keep color cadence consistent.
            pla = getOpp(movePla);
            continue;
        }
        history.makeBoardMoveAssumeLegal(board, loc, movePla, NULL);
        if (!isPass) {
            lastX = Location::getX(loc, size);
            lastY = Location::getY(loc, size);
        }
        pla = getOpp(movePla);
    }

    NSMutableData *cells = [NSMutableData dataWithLength:(NSUInteger)(size * size)];
    uint8_t *bytes = (uint8_t *)cells.mutableBytes;
    for (int y = 0; y < size; y++) {
        for (int x = 0; x < size; x++) {
            Color c = board.colors[Location::getLoc(x, y, size)];
            bytes[y * size + x] = (c == C_BLACK) ? GoColorBlack
                                : (c == C_WHITE) ? GoColorWhite : GoColorEmpty;
        }
    }

    // KataGo's numWhiteCaptures = white stones removed = Black's prisoners.
    return [[GoPosition alloc] initWithSize:size
                                      cells:cells
                                      lastX:lastX
                                      lastY:lastY
                              blackCaptures:board.numWhiteCaptures
                              whiteCaptures:board.numBlackCaptures];
}

@end
