# GoLearner — Roadmap

Target reference: **KataGo Anytime** (ChinChangYang/KataGo `ios-dev`,
`ios/KataGo iOS`). This roadmap brings GoLearner up to the reference's core
feature set: a real model pipeline, MLX + CoreML inference, human-style play,
a GTP console, and import/sharing tools.

Status legend: ✅ done · 🔸 partial · ⏳ deferred · ⬜ not started.

## Current status (updated after Phase 1)
Phase 1 was implemented **ahead of P0 on the current architecture** (GoBridge +
MCTS), since its user-facing value doesn't require the engine pivot. The GTP /
native-SGF *internals* named in the original Phase 1 wording are swapped in
later when P0 lands; the features themselves already ship.

- ✅ **A1** move navigation + win-rate bar
- ✅ **A2** SGF import/export (custom Swift codec)
- ✅ **A3** local game library (SwiftData) + autosave
- 🔸 **A4a** rules/komi + player assignment + New Game sheet (19×19 only)
- ⏳ **A4b** sub-19 board sizes — see note below
- ✅ **handicap** — fixed placement + SGF `AB`/`HA`/`PL` round-trip
- ✅ **R7** GIF export (P0-independent)

Test suite: **52 tests, 0 failures**; runtime `selfCheck OK` (corner best-move)
verified after A3 and A4a.

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

## Phase 0 — Engine pivot  ⚑ keystone
**P0. Full KataGo engine + in-process GTP seam.**
- Vendor KataGo `cpp/` (`command/`, `search/`, `game/`, `neuralnet/`, `core/`).
- Compile CoreML/ANE + MLX/GPU backends (`USE_MLX_BACKEND`); Simulator → CoreML.
- Add a `KataGoEngineIO`-style protocol driven by `GameSession`; repoint
  `GameState` at it. Retire `MCTS.swift` and `NNModel.decode` (engine owns
  search + `nneval` now).
- **Complexity:** high. **Risk:** build size, ANE/MLX parity. **Gate:** empty-
  board corner best-move + sane winrate via GTP `kata-analyze`.
- **Files:** `Engine/cpp/**` (expanded), new `GameSession.swift`,
  `KataGoEngine.swift`; `GameState.swift`, `project.yml`, `ARCHITECTURE.md`.

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
  loads natively (no conversion for the MLX path). *(med)*
- **R1. On-the-fly CoreML conversion** — port the reference Swift converter +
  `coremlbackend` so the ANE path also runs downloaded nets; compiled-model
  cache + clear-cache UI. Optional once MLX runs `.bin.gz` directly. *(high)*

## Phase 3 — Inference & strength
- **R3. MLX/GPU backend + GPU+ANE mux** — vendor `mlxbackend.cpp` + MLX;
  per-model backend picker (MLX / CoreML / GPU+ANE), search-thread + Winograd
  tuning. *(high)*
- **R5. Human SL net + rank/pro profiles** — meta encoder is in-tree post-P0;
  add the second `input_meta` model (via R2/R1), rank (20k–9d) + Pro profiles
  with fixed-visit budgets. *(high, revises #6)*

## Phase 4 — Tools & sharing
- **R4. GTP console** — Developer-mode raw command console over the native GTP
  seam (`list_commands`, `genmove`, `kata-analyze`, …). *(low after P0)*
- ✅ **R7. GIF export** — animated GIF via `ImageIO` (speed, size, coords, loop,
  final hold), share sheet. *(P0-independent; `GameGIF`, `GIFExportView`)*
- **R6. Photo import** — Vision board/stone recognition, tap-to-correct,
  next-player picker (reference `GobanRecogKit`). Engine-independent. *(high)*

---

## Recommended sequence
Original plan: `P0 → A1 → A2 → A3 → A4 → R2 → R3 → R5 → R4 → R7 → R6 → R1`

Revised after Phase 1 (Phase 1 shipped first, on current arch):
`A1 → A2 → A3 → A4a → handicap → R7` ✅ → **next candidate without P0:** `R6`
(photo import); `A4b` best deferred until **P0** (full engine masks natively) →
then **P0** unlocks `R2 → R3 → R5 → R4 → R1`.

## Explicitly deferred
iCloud/CloudKit sync, Watch/TV/Mac/Vision targets, widgets, opening books,
Apple-Intelligence commentary.
