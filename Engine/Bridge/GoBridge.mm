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
    // The position the game is replayed *from* for undo/snapshot: normally an
    // empty board with Black to move, but a handicap setup makes it the placed
    // stones with White to move. Undo/snapshot never rewind below this base.
    Board _initialBoard;
    Player _initialPla;
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
    [self resetWithBoardSize:size komi:komi koRule:_rules.koRule scoringRule:_rules.scoringRule];
}

- (void)resetWithBoardSize:(int)size komi:(float)komi koRule:(int)koRule scoringRule:(int)scoringRule {
    _size = size;
    _rules = Rules::getTrompTaylorish();  // area scoring, positional superko, matches net training
    _rules.komi = komi;
    _rules.koRule = koRule;
    _rules.scoringRule = scoringRule;
    _initialBoard = Board(size, size);   // empty base, Black first (non-handicap default)
    _initialPla = P_BLACK;
    [self restoreBaseThenReplay:0];
}

- (void)setupHandicapWithXs:(const int *)xs ys:(const int *)ys count:(int)count {
    Board board(_size, _size);
    for (int i = 0; i < count; i++) {
        Loc loc = Location::getLoc(xs[i], ys[i], _size);
        board.setStone(loc, C_BLACK);
    }
    _initialBoard = board;
    _initialPla = P_WHITE;               // Black has already placed; White opens
    [self restoreBaseThenReplay:0];
}

// Rebuild _board/_history from the replay base and re-apply the first `count`
// recorded moves. All rewind paths (reset, undo, snapshot, handicap setup) go
// through here so the base position is honored in exactly one place. Trailing
// moves beyond `count` are dropped from `_moves`.
- (void)restoreBaseThenReplay:(NSInteger)count {
    NSInteger n = (NSInteger)_moves.size();
    if (count < 0) count = 0;
    if (count > n) count = n;
    _board = _initialBoard;
    _history.clear(_board, _initialPla, _rules, 0);
    _sideToMove = _initialPla;
    std::vector<Loc> replay(_moves.begin(), _moves.begin() + count);
    _moves.clear();
    for (Loc loc : replay) {
        Player pla = _sideToMove;
        _history.makeBoardMoveAssumeLegal(_board, loc, pla, NULL);
        _moves.push_back(loc);
        _sideToMove = getOpp(pla);
    }
}

#pragma mark - Read-only state

- (int)boardSize { return _size; }
- (float)komi { return _rules.komi; }
- (int)koRule { return _rules.koRule; }
- (int)scoringRule { return _rules.scoringRule; }
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

- (BOOL)moveAtIndex:(NSInteger)index outX:(int *)x outY:(int *)y {
    *x = -1; *y = -1;
    if (index < 0 || index >= (NSInteger)_moves.size()) return NO;
    Loc loc = _moves[(size_t)index];
    if (loc == Board::PASS_LOC || loc == Board::NULL_LOC) return NO;
    *x = Location::getX(loc, _size);
    *y = Location::getY(loc, _size);
    return YES;
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
    if (_moves.empty()) return NO;   // nothing above the replay base
    [self restoreBaseThenReplay:(NSInteger)_moves.size() - 1];
    return YES;
}

- (GoBridge *)clone {
    GoBridge *c = [[GoBridge alloc] initWithBoardSize:_size komi:_rules.komi];
    c->_board = _board;
    c->_history = _history;
    c->_rules = _rules;
    c->_sideToMove = _sideToMove;
    c->_moves = _moves;
    c->_initialBoard = _initialBoard;
    c->_initialPla = _initialPla;
    return c;
}

- (GoBridge *)snapshotAtPly:(NSInteger)ply {
    // A clone rewound to `ply` moves above the replay base (0 = the base
    // position itself, i.e. empty board or handicap setup). KataGo has no
    // random-access rewind, so we replay through the shared base helper.
    GoBridge *c = [self clone];
    [c restoreBaseThenReplay:ply];
    return c;
}

#pragma mark - Neural-net inputs

- (void)fillSpatial:(float *)spatial global:(float *)global {
    MiscNNInputParams params;  // defaults: drawEquivalentWinsForWhite=0.5, no PDA, etc.
    NNInputs::fillRowV7(_board, _history, _sideToMove, params,
                        _size, _size, /*useNHWC=*/false, spatial, global);
}

@end
