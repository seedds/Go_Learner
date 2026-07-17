//
//  SavedGame.swift
//  GoLearner
//
//  SwiftData model for a persisted game. The SGF text is the source of truth
//  (see SGF.swift); the other fields are denormalized for the library list so
//  it can render without parsing every row. Persistence lives in the view
//  layer so GameState (and the hostless test bundle) never depend on SwiftData.
//

import Foundation
import SwiftData

@Model
final class SavedGame {
    var name: String
    var createdAt: Date
    var updatedAt: Date
    var boardSize: Int
    var moveCount: Int
    /// Ko / scoring rules (KataGo `Rules::KO_*` / `SCORING_*` raw values). Stored
    /// explicitly because SGF's `RU` tag doesn't round-trip KataGo rules exactly.
    /// Defaults (positional ko / area scoring = Tromp-Taylor-ish) also let
    /// SwiftData lightweight-migrate stores written before these fields existed.
    var koRuleRaw: Int = 1
    var scoringRuleRaw: Int = 0
    /// Full game in SGF; reconstructs the board and feeds thumbnails.
    var sgf: String

    init(name: String, boardSize: Int, komi: Float,
         koRuleRaw: Int = KoRule.positional.rawValue,
         scoringRuleRaw: Int = ScoringRule.area.rawValue) {
        let now = Date()
        self.name = name
        self.createdAt = now
        self.updatedAt = now
        self.boardSize = boardSize
        self.moveCount = 0
        self.koRuleRaw = koRuleRaw
        self.scoringRuleRaw = scoringRuleRaw
        self.sgf = SGF.serialize(SGFGame(boardSize: boardSize, komi: komi, moves: []))
    }
}
