# GoLearner — Roadmap

Target reference: **KataGo Anytime** (ChinChangYang/KataGo `ios-dev`,
`ios/KataGo iOS`). This roadmap brings GoLearner up to the reference's core
feature set: a real model pipeline, MLX + CoreML inference, human-style play,
a GTP console, and import/sharing tools.

Status legend: ✅ done · 🔸 partial · ⏳ deferred · ⬜ not started.

## Current status (updated after P0)
**P0 landed: the app now runs the full vendored KataGo engine in-process over
GTP** (MLX/GPU + CoreML/ANE mux, on-the-fly `.bin.gz`→CoreML conversion). This
merged the originally-separate R3 (MLX backend) and R1 (CoreML conversion) work
into the pivot, and retired the old GoBridge + MCTS + NNModel slice. Phase 1
features were reimplemented on the new seam (native GTP play/analysis; board,
review, GIF, thumbnails via the stateless `GoReplay` rules bridge).

- ✅ **P0** full KataGo engine + in-process GTP seam (incl. R3 MLX + R1 CoreML conversion)
- ✅ **A1** move navigation + win-rate bar
- ✅ **A2** SGF import/export (custom Swift codec; native `loadsgf`/`printsgf` available post-P0)
- ✅ **A3** local game library (SwiftData) + autosave
- 🔸 **A4a** rules/komi + player assignment + New Game sheet (19×19 only)
- ⏳ **A4b** sub-19 board sizes — now unblocked (engine masks natively via `rectangular_boardsize`)
- ✅ **handicap** — fixed placement + SGF `AB`/`HA`/`PL` round-trip
- ✅ **R7** GIF export

Test suite: **41 tests, 0 failures** (host-based; incl. a live-engine smoke
test); runtime self-check `genmove=Q16 (15,3)` (3-4 corner) verified in the sim.

### Deviations discovered during implementation
- **A4 split (a/b).** The bundled Core ML model input is hard-pinned to
  `[1,22,19,19]`. Smaller boards need KataGo's 19×19-buffer masking, which is a
  correctness-critical rework of the bridge fill + `NNModel.decode` + `MCTS`
  legal-mask + pass index (`area` vs `361`), gated per size by the runtime
  corner-move check. Split out as **A4b**; **A4a** shipped on 19×19.
- **Handicap deferred.** Because A3 autosaves via SGF, handicap must persist as
  SGF setup stones (`AB`/`HA`/`PL`) through the bridge + parser + reconstruction;
  otherwise reloads silently drop stones and desync turn order. Pulled out of
  A4a to keep it additive.
- **SwiftData migration fallback.** Adding non-optional fields to `SavedGame`
  broke in-place store migration at runtime; fixed with attribute defaults +
  a container-load fallback (`GoLearnerApp.makeContainer`) that rebuilds a
  fresh store rather than crash on launch.

## Architectural decision (supersedes MVP constraints)
GoLearner pivots from the "minimal vendored C++ slice" MVP to the reference's
architecture: **vendor the full KataGo `cpp/` engine and drive it in-process
over GTP**. This is the honest keystone — it makes downloadable nets, MLX,
human SL, and the GTP console cheap, instead of hand-porting each to Swift.

This revises three AGENTS.md hard constraints; ARCHITECTURE.md must be updated
alongside Phase 0:
- **#1 (bridge single-threaded / no engine on the actor):** replaced by the
  GTP engine seam (`GameSession` + a `KataGoEngineIO`-style protocol).
- **#4 (minimal C++, no MLX/GPU/search):** dropped — full search + `mlxbackend`.
- **#6 (fixed I/O, no `input_meta`):** relaxed for the human SL net (Phase 3).

Inference keeps **both** backends like the reference: **CoreML/ANE** (default,
power-efficient) and **MLX/GPU**, with a GPU+ANE mux. The Simulator is pinned
to CoreML (Metal is unreliable there).

## Dependency map
```
P0 full engine + GTP seam ──┬─ A1..A4 review/persistence/setup
                            ├─ R2 downloadable nets ─ R5 human SL
                            ├─ R3 MLX/GPU backend
                            ├─ R4 GTP console  (nearly free after P0)
                            └─ R1 CoreML conversion (ANE path optimization)
R7 GIF export ← A1     R6 photo import (engine-independent)
```

---

## Phase 0 — Engine pivot  ⚑ keystone  ✅ DONE
**P0. Full KataGo engine + in-process GTP seam.** *(shipped; absorbed R3 + R1.)*
- ✅ Vendored KataGo `cpp/` (`command/gtp`, `search/`, `game/`, `neuralnet/`,
  `core/`, `dataio/`, `program/`, `book/`) + the abseil/protobuf/katagocoreml
  subset + `mlx-swift` fork + the `KataGoSwift` interop framework, pruned to the
  reference's exact compile manifest. Pin: `Engine/katago/UPSTREAM.txt`.
- ✅ Compiled the MLX backend (`USE_MLX_BACKEND`) with the CoreML/ANE mux;
  Simulator pinned to CoreML `.cpuOnly`, device runs the GPU+ANE mux.
- ✅ `KataGoEngineIO` + `GameSession` + `GtpCommandBuilder`/`GtpAnalysisParser`;
  `GameState` repointed at the engine; `MCTS`/`NNModel`/`GoEngine`/`GoBridge`
  and the old `Engine/cpp` slice retired. Offline replay via `GoReplay`.
- **Gate met:** empty-board `genmove=Q16` (3-4 corner) + parsed `kata-analyze`.
- **Files:** `Engine/katago/**`, `Engine/Bridge/{KataGoGTP,GoReplay,GoTypes,
  InProcessKataGoEngine}`, `GoLearner/{GameSession,GtpCommandBuilder,
  GtpAnalysisParser,KataGoEngineIO,GoReplayKit,GameState}.swift`, `project.yml`.

## Phase 1 — Review, persistence, setup
Implemented on the current architecture (no P0 dependency).
- ✅ **A1. Move navigation + win-rate bar** — ⏮◀▶⏭ stepping, view-only off-tip,
  ply counter, win-rate bar. Bridge: `snapshot(atPly:)`.
- ✅ **A2. SGF import/export** — custom Swift SGF codec (`SGF.swift`), main-line
  parse, Share sheet + file importer. *(native KataGo SGF swaps in at P0.)*
- ✅ **A3. Local game library** — SwiftData (`SavedGame`), split-view list,
  Canvas thumbnails, autosave, swipe-delete, store-load fallback. No iCloud.
- 🔸 **A4a. Rules/komi + players + New Game sheet (19×19)** — ko/scoring pickers,
  komi stepper, per-side Human/AI; rules persisted on `SavedGame`. Bridge:
  `reset(…koRule:scoringRule:)`.
- ⏳ **A4b. Sub-19 board sizes** — 9/13 via the fixed 19×19 NN buffer + masking;
  correctness-critical decode rework (see deviations). Gated per size by the
  runtime corner-move check.
- ✅ **Handicap** — fixed-handicap placement + SGF `AB`/`HA`/`PL` round-trip
  through bridge (`setupHandicap`), parser, and reconstruction.

## Phase 2 — Models
- **R2. Downloadable networks** — catalog (b40c768, FD3, 9x9, Lionffen, …),
  `URLSession` download w/ progress, on-disk store, model picker. `.bin.gz`
  loads natively; point `InProcessKataGoEngine.launch` at the chosen path. *(med)*
- ✅ **R1. On-the-fly CoreML conversion** — landed with P0 (the vendored
  `katagocoreml` converts `.bin.gz`→CoreML at launch). Still open: the persistent
  compiled-model **cache** + clear-cache UI (reference's `CoreMLCacheKit`). *(low)*

## Phase 3 — Inference & strength
- ✅ **R3. MLX/GPU backend + GPU+ANE mux** — landed with P0 (`mlxbackend.cpp` +
  the vendored `mlx-swift`; device runs the `[0,100]` GPU+ANE mux). Still open: a
  per-model backend **picker** UI + Winograd tuning controls. *(remaining: low)*
- **R5. Human SL net + rank/pro profiles** — the meta encoder is in-tree; add the
  second `input_meta` human net (via R2), restore the `humanSL*` cfg keys, and add
  rank (20k–9d) + Pro profiles with fixed-visit budgets in `GtpCommandBuilder`.
  *(high)*

## Phase 4 — Tools & sharing
- **R4. GTP console** — Developer-mode raw command console over the native GTP
  seam (`list_commands`, `genmove`, `kata-analyze`, …). *(low after P0)*
- ✅ **R7. GIF export** — animated GIF via `ImageIO` (speed, size, coords, loop,
  final hold), share sheet. *(P0-independent; `GameGIF`, `GIFExportView`)*
- **R6. Photo import** — Vision board/stone recognition, tap-to-correct,
  next-player picker (reference `GobanRecogKit`). Engine-independent. *(high)*

---

## Recommended sequence
Shipped: `A1 → A2 → A3 → A4a → handicap → R7` (on the old arch) → **P0** (engine
pivot, which also delivered R3 + R1's converter).

Remaining, recommended order:
`A4b (sub-19, now unblocked) → R2 (downloadable nets) → R1-cache → R4 (GTP
console, nearly free) → R5 (human-SL profiles) → R6 (photo import) → R3-picker`.

## Explicitly deferred
iCloud/CloudKit sync, Watch/TV/Mac/Vision targets, widgets, opening books,
Apple-Intelligence commentary.
