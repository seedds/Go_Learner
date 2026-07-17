//
//  GoBridge.mm
//  GoLearner
//
//  Objective-C++ implementation bridging to the vendored KataGo engine subset.
//

#import "GoBridge.h"

#include <vector>
#include "board.h"
#include "boardhistory.h"
#include "rules.h"
#include "nninputs.h"
#include "modelversion.h"

const int GoBridgeNumSpatialFeatures = NNInputs::NUM_FEATURES_SPATIAL_V7; // 22
const int GoBridgeNumGlobalFeatures  = NNInputs::NUM_FEATURES_GLOBAL_V7;  // 19

namespace {
Player toPlayer(GoColor c) { return c == GoColorWhite ? P_WHITE : P_BLACK; }
}

@implementation GoBridge {
    Board _board;
    BoardHistory _history;
    Rules _rules;
    Player _sideToMove;
    // Recorded moves (Board::PASS_LOC for passes) so we can implement undo by replay.
    std::vector<Loc> _moves;
    int _size;
}

// Runs before the class receives its first message (including +alloc), which is
// before any C++ ivar (Board _board) is default-constructed. KataGo asserts that
// the Zobrist tables are initialized inside Board::init, so this MUST happen
// first. ScoreValue tables are a prerequisite of the scoring/feature code.
+ (void)initialize {
    if (self == [GoBridge class]) {
        ScoreValue::initTables();
        Board::initHash();
    }
}

- (instancetype)initWithBoardSize:(int)size komi:(float)komi {
    self = [super init];
    if (self) {
        [self resetWithBoardSize:size komi:komi];
    }
    return self;
}

- (void)resetWithBoardSize:(int)size komi:(float)komi {
    _size = size;
    _rules = Rules::getTrompTaylorish();  // area scoring, positional superko, matches net training
    _rules.komi = komi;
    _board = Board(size, size);
    _history.clear(_board, P_BLACK, _rules, 0);
    _sideToMove = P_BLACK;
    _moves.clear();
}

#pragma mark - Read-only state

- (int)boardSize { return _size; }
- (float)komi { return _rules.komi; }
- (GoColor)sideToMove { return _sideToMove == P_WHITE ? GoColorWhite : GoColorBlack; }
- (NSInteger)moveCount { return (NSInteger)_moves.size(); }
// KataGo's numWhiteCaptures = number of WHITE stones removed from the board,
// i.e. the prisoners Black has taken. So Black's capture count is numWhiteCaptures.
- (int)blackCaptures { return _board.numWhiteCaptures; }
- (int)whiteCaptures { return _board.numBlackCaptures; }
- (BOOL)gameFinished { return _history.isGameFinished ? YES : NO; }
- (BOOL)isNoResult { return _history.isNoResult ? YES : NO; }
- (float)finalWhiteMinusBlackScore { return _history.finalWhiteMinusBlackScore; }
- (GoColor)winner {
    if (_history.winner == C_BLACK) return GoColorBlack;
    if (_history.winner == C_WHITE) return GoColorWhite;
    return GoColorEmpty;
}

- (GoColor)stoneColorAtX:(int)x y:(int)y {
    if (x < 0 || y < 0 || x >= _size || y >= _size) return GoColorEmpty;
    Loc loc = Location::getLoc(x, y, _size);
    Color c = _board.colors[loc];
    return c == C_BLACK ? GoColorBlack : (c == C_WHITE ? GoColorWhite : GoColorEmpty);
}

- (void)lastMoveX:(int *)x y:(int *)y {
    *x = -1; *y = -1;
    for (auto it = _moves.rbegin(); it != _moves.rend(); ++it) {
        Loc loc = *it;
        if (loc != Board::PASS_LOC && loc != Board::NULL_LOC) {
            *x = Location::getX(loc, _size);
            *y = Location::getY(loc, _size);
            return;
        }
    }
}

#pragma mark - Legality & moves

- (BOOL)isLegalX:(int)x y:(int)y color:(GoColor)color {
    if (x < 0 || y < 0 || x >= _size || y >= _size) return NO;
    Loc loc = Location::getLoc(x, y, _size);
    return _history.isLegal(_board, loc, toPlayer(color)) ? YES : NO;
}

- (BOOL)playX:(int)x y:(int)y color:(GoColor)color {
    if (![self isLegalX:x y:y color:color]) return NO;
    Player pla = toPlayer(color);
    Loc loc = Location::getLoc(x, y, _size);
    _history.makeBoardMoveAssumeLegal(_board, loc, pla, NULL);
    _moves.push_back(loc);
    _sideToMove = getOpp(pla);
    return YES;
}

- (void)passForColor:(GoColor)color {
    Player pla = toPlayer(color);
    _history.makeBoardMoveAssumeLegal(_board, Board::PASS_LOC, pla, NULL);
    _moves.push_back(Board::PASS_LOC);
    _sideToMove = getOpp(pla);
}

- (BOOL)undo {
    if (_moves.empty()) return NO;
    std::vector<Loc> replay(_moves.begin(), _moves.end() - 1);
    // Rebuild from scratch.
    _board = Board(_size, _size);
    _history.clear(_board, P_BLACK, _rules, 0);
    _sideToMove = P_BLACK;
    _moves.clear();
    for (Loc loc : replay) {
        Player pla = _sideToMove;
        _history.makeBoardMoveAssumeLegal(_board, loc, pla, NULL);
        _moves.push_back(loc);
        _sideToMove = getOpp(pla);
    }
    return YES;
}

- (GoBridge *)clone {
    GoBridge *c = [[GoBridge alloc] initWithBoardSize:_size komi:_rules.komi];
    c->_board = _board;
    c->_history = _history;
    c->_rules = _rules;
    c->_sideToMove = _sideToMove;
    c->_moves = _moves;
    return c;
}

#pragma mark - Neural-net inputs

- (void)fillSpatial:(float *)spatial global:(float *)global {
    MiscNNInputParams params;  // defaults: drawEquivalentWinsForWhite=0.5, no PDA, etc.
    NNInputs::fillRowV7(_board, _history, _sideToMove, params,
                        _size, _size, /*useNHWC=*/false, spatial, global);
}

@end
