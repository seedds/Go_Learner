# AGENTS.md — GoLearner

Operational guide for AI coding agents. Read this first, then
[ARCHITECTURE.md](ARCHITECTURE.md) for the deep model. [README.md](README.md)
is the human-facing overview.

**One-liner:** iPhone (iOS 26, SwiftUI) Go app that runs the KataGo
`b18c384nbt` net on the Apple Neural Engine via Core ML. A vendored slice of
KataGo's C++ (rules + NN feature generation) is bridged to Swift with ObjC++.

---

## Commands (validated — copy/paste)

```bash
cd /Users/f2pgod/Documents/GoLearner

# 1. Regenerate the Xcode project (REQUIRED after editing project.yml OR after
#    adding/removing/renaming any source file — sources are path-globbed).
xcodegen generate

# 2. Build (iOS 26 simulator)
xcodebuild build -project GoLearner.xcodeproj -scheme GoLearner \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -configuration Debug

# 3. Test (6 bridge unit tests; the scheme's test action runs GoLearnerTests)
xcodebuild test -project GoLearner.xcodeproj -scheme GoLearner \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

Filter noisy output with:
`... 2>&1 | grep -iE 'error:|BUILD SUCCEEDED|BUILD FAILED|Test Case.*(passed|failed)|Executed [0-9]'`

### Fast C++ iteration (skip Xcode)
The engine subset compiles standalone on the host — use this to shake out C++
errors in seconds before a full build:
```bash
cd Engine/cpp
clang++ -std=gnu++17 -c -I. -I core -I game -I neuralnet \
  -DNO_GIT_REVISION -DOS_IS_IOS <file>.cpp -o /dev/null
```

### Runtime end-to-end check (Core ML on ANE)
DEBUG builds log a one-time self-check at launch. After install+launch in the sim:
```bash
xcrun simctl spawn "iPhone 17 Pro" log show --last 3m \
  --predicate 'process == "GoLearner"' --info --debug --style compact \
  2>&1 | grep selfCheck
# Expect: selfCheck OK: policyCount=361 bestMove=(<corner>) ... whiteLead≈+1
```
A **corner** best-move on the empty board is the signal that features+model+decode
are correct. Garbage moves (tengen/first line) ⇒ a feature-encoding regression.

---

## Hard constraints (do not violate)

1. **`GoBridge` (C++) is single-threaded, main-actor only.** Never call it from
   the `GoEngine` actor. Pattern: `GameState` (main actor) fills `[Float]`
   buffers from the bridge, then passes those value types to the engine.
2. **Regenerate after file changes.** `project.yml` globs `GoLearner/`,
   `Engine/Bridge/`, `Engine/cpp/`. A new `.swift`/`.cpp`/`.mm` won't be built
   until you re-run `xcodegen generate`.
3. **Keep Core ML on `.cpuAndNeuralEngine`** (`NNModel.init`). The simulator's
   Metal/GPU path is unreliable.
4. **Keep the C++ subset minimal.** Only add engine files if a needed symbol is
   missing; every added `.cpp` must compile with the flags above. Don't pull in
   GPU/MLX/OpenCL/search code.
5. **Decode math mirrors KataGo `nneval.cpp`.** If you touch `NNModel.decode`,
   preserve the exact steps/constants (`scoreMeanMultiplier=20`, White-perspective
   sign flip, legal-move masking). See ARCHITECTURE.md §2.3.
6. **Model I/O names are fixed:** inputs `input_spatial [1,22,19,19]`,
   `input_global [1,19]`; outputs `output_policy` (use **channel 0**), `out_value`,
   `out_miscvalue`, `out_ownership`. No `input_meta` (meta encoder v0).

## Traps already discovered (don't rediscover)

- **Zobrist init timing:** KataGo asserts `IS_ZOBRIST_INITALIZED` inside the
  `Board` constructor. C++ ivars construct at `+alloc`, *before* `-init` runs, so
  `ScoreValue::initTables()` + `Board::initHash()` are done in `GoBridge`'s
  `+initialize` (before the class's first message). Keep them there.
- **Turn order is enforced** by `BoardHistory::isLegal` (can't play same color
  twice). Always play as `sideToMove`.
- **Capture-count fields are inverted vs their names:** Black's prisoners =
  `board.numWhiteCaptures`. Handled in `GoBridge.mm` — don't "fix" it.
- **No native undo:** `GoBridge undo` replays all-but-last move.
- **ObjC→Swift name splitting:** the color getter is pinned with
  `NS_SWIFT_NAME(stoneColor(atX:y:))` because the importer mis-splits
  `...AtX:y:`. Add `NS_SWIFT_NAME` to any new ambiguous selector.
- **Tests are a standalone logic bundle** (no app host): they compile the
  bridge + C++ subset themselves, so **no `@testable import GoLearner`** (it
  would duplicate the `GoBridge` ObjC class).

---

## Where things live

| Task | File(s) |
|------|---------|
| Game logic / engine driving / state | `GoLearner/GameState.swift` (`@MainActor @Observable`) |
| Core ML load + I/O + decode | `GoLearner/NNModel.swift` |
| Off-main-thread inference | `GoLearner/GoEngine.swift` (`actor`) |
| Swift ⇄ C++ seam | `Engine/Bridge/GoBridge.{h,mm}` |
| Rules + NN features (C++) | `Engine/cpp/{game,neuralnet,core}/` |
| Board UI + input | `GoLearner/BoardView.swift` |
| Analysis overlay | `GoLearner/AnalysisOverlay.swift` |
| Project definition | `project.yml` (→ `xcodegen`) |
| Tests | `GoLearnerTests/GoBridgeTests.swift` |

## Definition of done (any change)
1. `xcodegen generate` (if files/settings changed).
2. Build succeeds (command 2).
3. `xcodebuild test` green (command 3).
4. For engine/feature/decode changes: launch in sim, confirm `selfCheck OK`
   with a corner best-move.

## Conventions
- Match KataGo semantics exactly for anything touching rules/features/decode;
  cite the upstream source location in a comment when non-obvious.
- Keep changes surgical; don't refactor the vendored C++.
- Prefer extending the `GoEngine`/`NNResult` seam over widening the bridge.
- MVP intentionally excludes MCTS, SGF, multi-size, iCloud — see ARCHITECTURE.md
  §6 before adding; keep the `GameState` API stable when you do.
```
