# GoLearner — Architecture

A deeper map of the codebase for developers and AI agents. Read
[README.md](README.md) first for the high-level picture, then
[AGENTS.md](AGENTS.md) for the operational rules. This document records the
**non-obvious contracts and gotchas** so you don't have to rediscover them.

After the **P0 engine pivot**, GoLearner embeds the *full* KataGo engine and
drives it in-process over GTP — it is no longer a hand-ported NN slice.

---

## 1. Layers & responsibilities

| Layer | File(s) | Thread | Responsibility |
|-------|---------|--------|----------------|
| UI | `ContentView`, `BoardView`, `AnalysisOverlay` | main | Render board + overlay, capture taps |
| Model | `GameState` | `@MainActor` | Owns the move-list record + observable state; drives the engine; renders via `GoReplay` |
| Session | `GameSession` | `actor` | Serializes GTP request/response; genMove; analyzeOnce |
| Transport | `KataGoEngineIO` / `InProcessKataGoEngine` | — | GTP command/line I/O to the engine (process-global) |
| GTP bridge | `KataGoGTP.{h,mm}` | engine thread | Rebinds engine `cout`/`cin`; runs `MainCmds::gtp` |
| Replay bridge | `GoReplay.{h,mm}` | any | Stateless move-list → board position (KataGo rules) |
| Engine | `Engine/katago/cpp/**` | engine + NN threads | Full KataGo: rules, search, native SGF, MLX/CoreML NN |
| NN backend | `KataGoSwift/metalbackend.swift` | NN-server threads | CoreML/ANE + MLX/GPU inference, on-the-fly conversion |

**Golden rule:** there is **one engine per process**. Everything that plays or
analyzes the live game goes through the single `GameSession`. Anything that needs
a board position *without* disturbing the live game (rendering, review, GIF,
thumbnails) uses the stateless `GoReplay` — never a second engine.

---

## 2. The engine seam

### 2.1 Launch
`InProcessKataGoEngine.launch(modelPath:configPath:)` starts `MainCmds::gtp` on a
dedicated `Thread` with **`stackSize = 4096 * 2048`** (8 MB — `ScoreValue::initTables()`
overflows the default 512 KB stack, and `final_score` runs a whole search inline on
this thread). The engine's internal search/callback/NN-server `std::thread`s default
to iOS's 512 KB, so they are spawned through `LargeStackThread` (4 MB). `KataGoGTP` rebinds the engine's global
`cout`/`cin` to two thread-safe stream buffers, so Swift talks GTP without a
subprocess (iOS forbids spawning one). Launch is idempotent and suppressed under
XCTest (the test owns the engine).

Backend device assignments (one code per NN-server thread; `0` = MLX/GPU,
`100` = CoreML/ANE):
- **Simulator:** `[100]` — MLX GPU crashes in the sim's Metal translation layer.
- **Device:** `[0, 100]` — the GPU+ANE mux.

### 2.2 Model
- **Net:** `b18c384nbt` (18-block), bundled as `Resources/default_model.bin.gz`
  (~93 MB). Converted to CoreML **on the fly at launch** by the vendored
  `katagocoreml` library (no `.mlpackage` is bundled or downloaded).
- **Config:** `Resources/default_gtp.cfg`, copied from the reference with the
  `humanSL*` keys stripped (no human-SL net is bundled; the engine throws in
  `Setup::loadParams` if those keys are present without the model).
- **Compute units:** `.cpuOnly` on the Simulator, `.cpuAndNeuralEngine` on device
  (`KataGoSwift/metalbackend.swift`).

### 2.3 Commands & parsing
`GtpCommandBuilder` builds the command strings (vertex mapping skips column `I`,
rows count from the bottom; `boardsize`, `komi`, `kata-set-rule`, `play`,
`loadsgf`, `genmove`, `kata-analyze`). `GtpAnalysisParser` turns one
`kata-analyze` report into candidates + ownership + rootInfo. **winrate/scoreLead
are emitted from White's perspective** (the shipped `reportAnalysisWinratesAs =
WHITE`); the `WinProb.fromWhite` helper is the single place that conversion to
the side-to-move / Black perspective lives, used by `GameState.nnResult(from:)`,
the status summary, and the win-rate bar.

---

## 3. Live game vs. offline replay

`GameState` keeps the live game as a **Swift move-list record** (`[ReplayMove]`)
and mirrors every live move to the engine (`play` / `genmove` / `undo`). The
observable board state (`stones`, captures, `lastMove`, `sideToMove`) is recomputed
by replaying that record through `GoReplay` at the viewed ply — so review
*navigation* is just a `plyLimit`, and the live game (and engine) is never
disturbed by stepping through it. GIF frames and library thumbnails use the same
replay path. Playing a move *while* reviewing is the one exception: a tap at a
past ply **branches** — `humanPlay` truncates the record to the viewed ply,
appends the new stone, and rebuilds the engine to that line via
`syncEngineToRecord`. So reviewing is render-only, but a deliberate move from a
past position starts a new line (there is no separate "confirm branch" step).

`GoReplay` builds a fresh `Board`/`BoardHistory` per call, applies KataGo's rules
(captures, ko, legality), and returns a stone grid. It calls `Board::initHash()`
(guarded by `std::call_once`, shared safely with the engine) but **not**
`ScoreValue::initTables()` (replay needs only rules, and double-init would trip
the engine's single-init assertion).

Every replay (and the live game) sits on a **setup base** — a `SetupPosition`
(`GoLearner/SetupPosition.swift`): pre-placed Black *and* White stones plus the
side to move. An even game is the empty base; a handicap is black stones with
White to move; an edited/photo-imported puzzle is an arbitrary base. The
side-to-move shown at any ply is `setup.toMove` flipped once per applied move —
**not** `!handicap.isEmpty` — so White-to-play positions render and play
correctly. The base persists through SGF `AB`/`AW`/`PL`.

## 3.1 Setup positions: editor & photo import

The free board editor (`EditorBoard` pure model + `BoardEditorView`) and photo
import both produce a `SetupPosition`, committed via `GameState.commitSetup`.
Because arbitrary two-color positions with an explicit turn can't go through
`set_position` (it forces Black to move), `syncEngineToRecord` writes a temp SGF
and drives **`loadsgf`** for any non-empty base, then re-applies app komi/rules
(which preserve the loaded position). A base is validated with
`GoReplayKit.isPlaceableSetup` (the engine's own `setStonesFailIfNoLibs`) before
commit, so a zero-liberty group can't desync the engine from the UI.

Photo/camera import (`GoLearner/Recognition/**`) is a heuristic pipeline:
`VNDetectRectangles` finds the board quad → `CIPerspectiveCorrection` rectifies
it → `BoardImageAnalysis` (pure, tested) classifies each intersection's luma
against the board background. The `BoardRecognizer` protocol seams this so the
reference's OpenCV C++ recognizer can replace `VisionBoardRecognizer` later. A
recognized board opens in the editor for tap-to-correct, sharing the commit path
with hand-built puzzles.

---

## 4. Gotchas discovered (don't relearn these)

1. **One engine per process / one reader.** Two `getMessageLine()` readers on the
   shared GTP output deadlock. `GameState` skips engine launch under XCTest, and
   holds a single `GameSession` for the process lifetime (board size is a
   per-command parameter, so switching sizes never rebuilds the session).
2. **8 MB engine thread stack** — see §2.1.
3. **Capture-count fields are inverted vs their names:** KataGo's
   `numWhiteCaptures` = white stones removed = Black's prisoners. Handled in
   `GoReplay.mm`.
4. **GTP vertex mapping:** columns skip `I`; rows count from the bottom; board
   coords are 0-indexed with y from the top. See `GtpCommandBuilder.vertex` /
   `GtpAnalysisParser.vertexToPosition`.
5. **Simulator CoreML** must be `.cpuOnly`; MLX GPU is device-only.
6. **xcodegen man-page trap:** a vendored dir named `foo.1` is mis-typed as a man
   page and dropped from compilation. The external trees are named
   `abseil-cpp-20260107` / `protobuf-34` (no `.N`) and pruned to the reference's
   exact compile manifest.

---

## 5. Control flow: a move

```
User taps intersection
  └─ BoardView tap → GameState.humanPlay(x,y)
       ├─ GoReplay.isLegal(base + candidate)         // rules check, engine-free
       ├─ (if reviewing) truncate record to viewed ply — branch a new line
       ├─ append to move record; generation/recordVersion += 1; refreshFromRecord()
       └─ Task:
            ├─ branch → session syncEngineToRecord()  // rebuild engine to the line
            │  else   → session.command("play <color> <vertex>")  // mirror one move
            └─ advance()
                 ├─ if next player is AI → playAIMove()
                 │     ├─ session set maxVisits/maxTime
                 │     ├─ vertex = await session.genMove(color)
                 │     ├─ guard generation unchanged (drop stale results)
                 │     └─ applyGenMove(vertex): vertex/pass append a move,
                 │        "resign" ends the game → refreshFromRecord() → advance()
                 └─ else if analysisEnabled → runAnalysis()
                       └─ loop: session.analyzeOnce → NNResult (overlay), until the
                          position changes or root visits hit the cap (streaming)
```

**Staleness:** every state mutation bumps `GameState.generation`. Async engine
results compare their captured token against the current one and no-op if the
user has moved on. A parallel `recordVersion` counter bumps on every
*persistable* change (played move, resignation, new/configured/committed/imported
game); `RootView` observes it to autosave — including 0-move edits that
`totalMoves` alone would miss.

---

## 6. Where to extend

| Goal | Touch |
|------|-------|
| Downloadable nets / model picker | Model store + `InProcessKataGoEngine.launch` model path; catalog UI. See ROADMAP R2 |
| Human-SL profiles | Bundle the human net, restore `humanSL*` cfg, add profile → visit-budget in `GtpCommandBuilder`. ROADMAP R5 |
| GTP console | A view over `GameSession` raw command/line I/O. ROADMAP R4 |
| Sub-19 board sizes | `GameState.boardSize`, `boardsize` GTP command, star points in `BoardView`. ROADMAP A4b |
| Setup positions / puzzles | `SetupPosition`, `GameState.commitSetup`, `EditorBoard`/`BoardEditorView`; `loadsgf` sync |
| Better photo recognition | Implement `BoardRecognizer` (e.g. port OpenCV `GobanRecogKit`); swap for `VisionBoardRecognizer` |
| Learning features | New views reading `NNResult` / `GtpAnalysis` |

---

## 7. Verification gates

- **G1** `katago` static lib + `KataGoSwift` framework build for the iOS Sim.  ✅
- **G2** In-process GTP handshake + rules commands (no NN).  ✅
- **G3** `genmove` on the empty board returns a corner/star-point.  ✅
- **G4** `kata-analyze` parses into candidates + rootInfo; winrate sane.  ✅
- **G5** `xcodebuild test` green (host-based tests incl. live-engine smoke).  ✅

In-app startup self-check (`GameState.selfCheck`, DEBUG, os_log), observed on the
iPhone 17 Pro / iOS 26 simulator:
```
GoLearner selfCheck genmove=Q16 (15,3)
```
`(15,3)` is a **3-4 corner point** — a strong net's natural opening, the key
end-to-end signal that model load + CoreML conversion + inference + GTP decode
are all correct (a wrong encoding yields tengen/first-line garbage, not a corner).
