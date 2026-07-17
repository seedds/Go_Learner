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
dedicated `Thread` with **`stackSize = 4096 * 256`** (1 MB — `ScoreValue::initTables()`
overflows the default 512 KB stack). `KataGoGTP` rebinds the engine's global
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
`genmove`, `fixed_handicap`, `kata-analyze`). `GtpAnalysisParser` turns one
`kata-analyze` report into candidates + ownership + rootInfo. **winrate/scoreLead
are emitted from White's perspective** (the shipped `reportAnalysisWinratesAs =
WHITE`); `GameState.nnResult(from:)` converts to the side-to-move / Black
perspective the UI expects.

---

## 3. Live game vs. offline replay

`GameState` keeps the live game as a **Swift move-list record** (`[ReplayMove]`)
and mirrors every live move to the engine (`play` / `genmove` / `undo`). The
observable board state (`stones`, captures, `lastMove`, `sideToMove`) is recomputed
by replaying that record through `GoReplay` at the viewed ply — so review
navigation is just a `plyLimit`, and the live game (and engine) is never disturbed
while reviewing. GIF frames and library thumbnails use the same replay path.

`GoReplay` builds a fresh `Board`/`BoardHistory` per call, applies KataGo's rules
(captures, ko, legality), and returns a stone grid. It calls `Board::initHash()`
(guarded by `std::call_once`, shared safely with the engine) but **not**
`ScoreValue::initTables()` (replay needs only rules, and double-init would trip
the engine's single-init assertion).

---

## 4. Gotchas discovered (don't relearn these)

1. **One engine per process / one reader.** Two `getMessageLine()` readers on the
   shared GTP output deadlock. `GameState` skips engine launch under XCTest.
2. **1 MB engine thread stack** — see §2.1.
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
       ├─ GoReplay.isLegal(record + candidate)      // rules check, engine-free
       ├─ append to move record; generation += 1; refreshFromRecord() (GoReplay)
       └─ Task:
            ├─ session.command("play <color> <vertex>")   // mirror to engine
            └─ advance()
                 ├─ if next player is AI → playAIMove()
                 │     ├─ session set maxVisits/maxTime
                 │     ├─ vertex = await session.genMove(color)
                 │     ├─ guard generation unchanged (drop stale results)
                 │     └─ append engine move → refreshFromRecord() → advance()
                 └─ else if analysisEnabled → runAnalysis()
                       └─ session.analyzeOnce → GtpAnalysisParser → NNResult (overlay)
```

**Staleness:** every state mutation bumps `GameState.generation`. Async engine
results compare their captured token against the current one and no-op if the
user has moved on.

---

## 6. Where to extend

| Goal | Touch |
|------|-------|
| Downloadable nets / model picker | Model store + `InProcessKataGoEngine.launch` model path; catalog UI. See ROADMAP R2 |
| Human-SL profiles | Bundle the human net, restore `humanSL*` cfg, add profile → visit-budget in `GtpCommandBuilder`. ROADMAP R5 |
| GTP console | A view over `GameSession` raw command/line I/O. ROADMAP R4 |
| Sub-19 board sizes | `GameState.boardSize`, `rectangular_boardsize`, star points in `BoardView`. ROADMAP A4b |
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
