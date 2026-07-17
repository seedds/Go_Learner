# GoLearner — Architecture

A deeper map of the codebase for developers and AI agents. Read
[README.md](README.md) first for the high-level picture. This document records
the **non-obvious contracts and gotchas** so you don't have to rediscover them.

---

## 1. Layers & responsibilities

| Layer | File(s) | Thread | Responsibility |
|-------|---------|--------|----------------|
| UI | `ContentView`, `BoardView`, `AnalysisOverlay` | main | Render board + overlay, capture taps |
| Model | `GameState` | `@MainActor` | Owns C++ bridge, drives the engine, holds all observable state |
| Engine | `GoEngine` | `actor` | Runs Core ML off the main thread |
| Core ML | `NNModel` | (called on actor) | Load model, marshal I/O, decode outputs |
| Bridge | `GoBridge.{h,mm}` | main (single-threaded) | Board state, legality, NN feature generation |
| C++ | `Engine/cpp/**` | — | KataGo board/rules/features (vendored subset) |

**Golden rule:** the C++ `GoBridge` is **not** thread-safe and must only be
touched from the main actor. `GameState` fills feature arrays (plain `[Float]`)
on the main actor, then hands those value types to `GoEngine`. The stateful C++
object never crosses a thread boundary.

---

## 2. The neural network

- **Net:** `b18c384nbt`, an 18-block KataGo network. **Model version 14**, which
  maps to **inputs version 7** (`NNModelVersion::getInputsVersion(14) == 7`).
- **File:** `Resources/KataGoModel19x19fp16.mlpackage` (fp16, ~55 MB). At build
  time Xcode compiles it to `KataGoModel19x19fp16.mlmodelc` in the app bundle;
  `NNModel` loads that compiled form.
- **Compute units:** `.cpuAndNeuralEngine` (matches the reference's default,
  best power/throughput; avoids the GPU which the simulator dislikes).

### 2.1 Inputs (from the C++ bridge, `fillRowV7`)

| Feature | Core ML name | Shape | Notes |
|---------|--------------|-------|-------|
| Spatial | `input_spatial` | `[1, 22, 19, 19]` | 22 channels, NCHW (channel, y, x), row-major |
| Global  | `input_global`  | `[1, 19]` | 19 scalars (rules, komi, history flags) |

There is **no** `input_meta` — this net has meta encoder version 0.

Both buffers are produced by `NNInputs::fillRowV7(...)` in the vendored C++,
**from the perspective of the side to move**. `GoBridge fillSpatial:global:`
wraps this. Channel 0 of the spatial tensor is the on-board mask (all 1.0 for a
19×19 board → sums to 361, a handy sanity check).

### 2.2 Outputs (decoded in `NNModel.decode`)

| Core ML name | Meaning | Used for |
|--------------|---------|----------|
| `output_policy` | Move logits, channel-major `[1, C, 362]`; **channel 0** is the main policy; index 0..360 = board, 361 = pass | Move selection + candidate overlay |
| `out_value` | `[win, loss, noResult]` logits (to-move perspective) | Win-rate bar / status |
| `out_miscvalue` | `[0]=scoreMean, [2]=lead, …` (pre-scale) | Score lead display |
| `out_moremiscvalue` | shortterm errors etc. | (unused in MVP) |
| `out_ownership` | `[1, 1, 19, 19]` raw ownership (pre-tanh) | Territory shading |

### 2.3 Decode math (mirrors `nneval.cpp`)

These constants come from KataGo `desc.cpp` defaults; the Core ML model is
converted straight from the checkpoint, so `outputScaleMultiplier = 1.0`:

- `scoreMeanMultiplier = 20.0`, `leadMultiplier = 20.0`.

Steps (see `NNModel.decode`):

1. **Policy:** mask illegal positions (from the bridge), subtract max logit,
   `exp`, normalize over legal moves. Pass is index `area`.
2. **Value:** softmax over `[win, loss, noResult]`.
3. **Score/lead:** `raw * outputScaleMultiplier * 20.0 * (1 - noResultProb)`,
   then **flip sign to White's perspective** (`sign = blackToMove ? -1 : +1`).
4. **Ownership:** `tanh(raw * outputScaleMultiplier)`, same White-perspective
   sign flip, per point.

The network speaks from the **player to move**; everything score/ownership-wise
is converted to **White's perspective** on decode (KataGo's convention), and the
UI converts to Black's win% for display in `GameState.winrateSummary`.

> If you add MCTS or use `out_moremiscvalue`, extend `decode` — the raw layout
> is documented in `Engine/cpp/neuralnet/nninputs.h` (`NNOutput`) and the
> reference's `coremlbackend.cpp` (`CoreMLProcess::processScoreValues`).

---

## 3. The C++ subset (`Engine/cpp/`)

Only the files needed for **board rules + NN feature generation** are vendored
from KataGo (`ios-dev` branch). No GPU/MLX/OpenCL/search code.

- `game/board.cpp` — board, stones, chains, captures, legality primitives.
- `game/boardhistory.cpp` — turn order, ko/superko, move history, scoring.
- `game/rules.cpp` — rule sets (uses `nlohmann_json`).
- `neuralnet/nninputs.cpp` — `fillRowV7` (features) **and** `ScoreValue` tables.
- `neuralnet/modelversion.cpp` — maps model version → feature counts.
- `core/*` — hashing, RNG, math, utils these depend on.

### Compile flags (must match to keep engine headers consistent)

```
-std=gnu++17  -DNO_GIT_REVISION  -DOS_IS_IOS
-I Engine/cpp -I Engine/cpp/core -I Engine/cpp/game -I Engine/cpp/neuralnet
```

`COMPILE_MAX_BOARD_LEN` defaults inside the headers; the MVP uses 19×19.

### One-time init (order matters)

`GoBridge` calls, exactly once:

```cpp
ScoreValue::initTables();   // must be first — nninputs/scoring depend on it
Board::initHash();          // Zobrist tables
```

---

## 4. Gotchas discovered (don't relearn these)

1. **Turn order is enforced by the engine.** `BoardHistory::isLegal` returns
   false if `movePla != presumedNextMovePla`. You cannot play two Blacks in a
   row. `GameState` always plays as `sideToMove`.
2. **Capture-count field mapping is inverted from the intuitive name.**
   KataGo's `board.numWhiteCaptures` = number of *White stones removed* = the
   prisoners **Black** has taken. So:
   - `blackCaptures` (shown by Black) ← `numWhiteCaptures`
   - `whiteCaptures` (shown by White) ← `numBlackCaptures`
   (Handled in `GoBridge.mm`.)
3. **No native undo in KataGo.** `GoBridge undo` rebuilds the position by
   replaying all moves except the last. Fine for MVP move counts.
4. **`makeBoardMoveAssumeLegal` takes a `KoHashTable*`** — pass `NULL`.
5. **Simulator + Metal/GPU is flaky.** Keep Core ML on `.cpuAndNeuralEngine`.
6. **Policy output has multiple channels** (optimism head). Always read
   **channel 0**; `NNModel.policyPositionStride` derives the position stride
   from the array shape rather than hard-coding it.

---

## 5. Control flow: a move

```
User taps intersection
  └─ BoardView tap → GameState.humanPlay(x,y)
       ├─ GoBridge.play(x,y,sideToMove)      // C++ legality + apply
       ├─ generation += 1; refreshFromBridge()
       └─ Task → advance()
            ├─ if next player is AI → playAIMove()
            │     ├─ evaluateCurrent(): fill features + legal mask (main actor)
            │     ├─ await GoEngine.evaluate(...) (actor, Core ML on ANE)
            │     ├─ guard generation unchanged (drop stale results)
            │     ├─ pick best legal policy move → GoBridge.play/pass
            │     └─ advance()  // chains for AI-vs-AI or refreshes analysis
            └─ else if analysisEnabled → runAnalysis() (overlay only)
```

**Staleness:** every state mutation bumps `GameState.generation`. Async engine
results compare their captured token against the current one and no-op if the
user has moved on. This is the concurrency safety net.

---

## 6. Where to extend

| Goal | Touch |
|------|-------|
| MCTS / stronger play | `GoEngine` (add search over repeated `NNModel` evals); keep `GameState` API |
| Other board sizes | `GameState.boardSize`, `GoBridge init`, star points in `BoardView`; the same net handles ≤19 |
| SGF / game library | New store + `GameState` load/save; bridge already tracks move history |
| Learning features (tsumego, "why this move") | New views reading `NNResult`; consider a problems store |
| Score estimation UI | Already have `whiteLead` + ownership; add a dead-stone/territory pass |

---

## 7. Verification gates (MVP)

- **G1** C++ subset compiles + links for iOS Simulator (arm64).  ✅
- **G2** Bridge round-trip: legality, capture, turn-order, undo, feature shape.  ✅ 6/6 unit tests
- **G3** Core ML loads; outputs have expected shapes (policyCount == 361).  ✅
- **G4** Decoded win rate/policy sane (empty board ≈ balanced).  ✅
- **G5** `xcodebuild build` + unit tests green on iPhone 17 / iOS 26.  ✅

In-app startup self-check (`GameState.selfCheck`, DEBUG, logged via os_log),
observed on the iPhone 17 Pro / iOS 26 simulator:
```
GoLearner selfCheck OK: policyCount=361 bestMove=(15,3) p=0.161
                        winToMove=0.373 whiteLead=1.12 own[0]=0.003
```
`bestMove=(15,3)` is a **corner (3-4 point)** — a strong net's natural opening,
which is the key end-to-end signal that the feature encoding + model + decode
are all correct (a wrong encoding yields nonsense moves, not a corner). The
whiteLead ≈ +1.1 with komi 7.5 (Black's first-move value ≈ 6.4 pts) is realistic.
