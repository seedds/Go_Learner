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

- (GoColor)colorAtX:(int)x y:(int)y {
    if (x < 0 || y < 0 || x >= _size || y >= _size) return GoColorEmpty;
    const uint8_t *bytes = (const uint8_t *)_cells.bytes;
    return (GoColor)bytes[y * _size + x];
}

@end

// Replay handicap + the first `moveCount` moves into `board`/`history`, leaving
// `pla` as the side to move. Shared by position building and legality checks.
static Player replayInto(Board &board, BoardHistory &history, int size,
                         const int *hxs, const int *hys, int handicapCount,
                         const int *mxs, const int *mys, const int *mcolors,
                         int moveCount, int limit) {
    Rules rules = Rules::getTrompTaylorish();
    Player initialPla = P_BLACK;
    if (handicapCount > 0 && hxs && hys) {
        for (int i = 0; i < handicapCount; i++) {
            board.setStone(Location::getLoc(hxs[i], hys[i], size), C_BLACK);
        }
        initialPla = P_WHITE;
    }
    history.clear(board, initialPla, rules, 0);
    Player pla = initialPla;
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

+ (BOOL)isLegalWithBoardSize:(int)size
                  handicapXs:(const int *)hxs
                  handicapYs:(const int *)hys
               handicapCount:(int)handicapCount
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
    replayInto(board, history, size, hxs, hys, handicapCount, mxs, mys, mcolors, moveCount, -1);
    Player pla = (candColor == GoColorWhite) ? P_WHITE : P_BLACK;
    if (candX < 0) return YES;   // pass is always legal
    Loc loc = Location::getLoc(candX, candY, size);
    return history.isLegal(board, loc, pla) ? YES : NO;
}

+ (GoPosition *)positionWithBoardSize:(int)size
                        handicapXs:(const int *)hxs
                        handicapYs:(const int *)hys
                     handicapCount:(int)handicapCount
                            moveXs:(const int *)mxs
                            moveYs:(const int *)mys
                        moveColors:(const int *)mcolors
                         moveCount:(int)moveCount
                          plyLimit:(int)plyLimit {
    ensureHashInit();

    Rules rules = Rules::getTrompTaylorish();
    Board board(size, size);
    Player initialPla = P_BLACK;

    // Handicap: place black stones directly, White moves first.
    if (handicapCount > 0 && hxs && hys) {
        for (int i = 0; i < handicapCount; i++) {
            Loc loc = Location::getLoc(hxs[i], hys[i], size);
            board.setStone(loc, C_BLACK);
        }
        initialPla = P_WHITE;
    }

    BoardHistory history;
    history.clear(board, initialPla, rules, 0);
    Player pla = initialPla;

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
