# AGENTS.md — GoLearner

Operational guide for AI coding agents. Read this first, then
[ARCHITECTURE.md](ARCHITECTURE.md) for the deep model. [README.md](README.md)
is the human-facing overview.

**One-liner:** iPhone (iOS 26, SwiftUI) Go app that runs the **full vendored
KataGo engine in-process over GTP**. The engine's `b18c384nbt` net runs on the
Apple Neural Engine (CoreML) — with an MLX/GPU path on device — converted from
`.bin.gz` at launch. Swift drives the engine through a thin ObjC++ GTP bridge;
board/review/GIF rendering replays moves through a separate stateless rules
bridge (`GoReplay`).

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

# 3. Test (host-based GoLearnerTests: pure parsers/SGF/replay + a live-engine
#    smoke test)
xcodebuild test -project GoLearner.xcodeproj -scheme GoLearner \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

Filter noisy output with:
`... 2>&1 | grep -iE 'error:|BUILD SUCCEEDED|BUILD FAILED|Test Case.*(passed|failed)|Executed [0-9]'`

**First build is slow & needs the Metal Toolchain** (MLX compiles Metal kernels):
`xcodebuild -downloadComponent MetalToolchain` once, if you see
`cannot execute tool 'metal'`.

### Fast C++ iteration (skip Xcode)
The vendored engine compiles standalone on the host — shake out C++ errors in
seconds before a full build (most engine TUs need only the core/game/neuralnet
headers; the MLX backend needs the framework's generated Swift header, so build
those in Xcode):
```bash
cd Engine/katago/cpp
SDK=$(xcrun --sdk iphonesimulator --show-sdk-path)
clang++ -std=gnu++17 -c -I. -Icore -Igame -Ineuralnet -Isearch -Iprogram \
  -Ibook -Idataio -Iexternal -Iexternal/nlohmann_json \
  -DNO_GIT_REVISION -DOS_IS_IOS -DCOMPILE_MAX_BOARD_LEN=37 \
  -isysroot "$SDK" -arch arm64 -mios-simulator-version-min=26.0 -w \
  <file>.cpp -o /dev/null
```

### Runtime end-to-end check
DEBUG builds log a one-time self-check at launch. After the app runs in the sim:
```bash
xcrun simctl spawn "iPhone 17 Pro" log show --last 3m \
  --predicate 'process == "GoLearner"' --info --debug 2>&1 | grep selfCheck
# Expect: GoLearner selfCheck genmove=Q16 (15,3)   ← a 3-4 corner point
```
A **corner / star-point** opening on the empty board is the signal that model
load + CoreML conversion + inference + GTP decode are correct. Tengen/first-line
garbage ⇒ a feature-encoding or decode regression.

---

## Hard constraints (do not violate)

1. **One engine per process.** The KataGo engine and its GTP stdin/stdout stream
   buffers are process-global. Drive it only through `GameSession` over a single
   `KataGoEngineIO`. Never spin up a second reader (it deadlocks on the shared
   output). `GameState` suppresses engine launch under XCTest so the test owns it.
2. **The engine GTP loop needs an 8 MB thread stack.** `ScoreValue::initTables()`
   overflows the default 512 KB stack, and some GTP commands (`final_score`) run a
   whole search INLINE on this thread on top of ~274 KB of by-value `BoardHistory`
   locals. `InProcessKataGoEngine` sets `thread.stackSize = 4096 * 2048` — keep it.
   The engine's *internal* threads (search/analyze-callback/NN-server) are `std::thread`s
   that default to iOS's 512 KB, so they're spawned via `LargeStackThread`
   (`Engine/katago/cpp/core/largestackthread.h`) with a 4 MB stack — keep those too.
3. **Simulator = CoreML/CPU; device = GPU+ANE mux.** MLX GPU inference crashes in
   the simulator's Metal translation layer, and the sim has no ANE, so CoreML is
   pinned to `.cpuOnly` there (`KataGoSwift/metalbackend.swift`,
   `#if targetEnvironment(simulator)`), and device assignments are `[100]` (ANE)
   in the sim vs `[0,100]` (GPU+ANE) on device (`InProcessKataGoEngine`).
4. **`GoReplay` is the offline board authority; the engine is the live-game
   authority.** Rendering, review navigation, GIF frames, and library thumbnails
   replay the Swift move-list through `GoReplay` (stateless, KataGo rules, no
   engine). Never route offline replay through the single engine.
5. **Regenerate after file changes.** `project.yml` globs `GoLearner/`,
   `Engine/Bridge/`, `Engine/katago/cpp/`, `Engine/katago/KataGoSwift/`. A new
   source won't build until you re-run `xcodegen generate`.
6. **Don't re-globify the vendored external trees.** `abseil-cpp-20260107/` and
   `protobuf-34/` are pruned to exactly the reference's compile manifest; their
   dir names must NOT end in `.N` (xcodegen mis-types `foo.1` as a man page and
   drops the whole tree). If you re-vendor, prune to the manifest and keep the
   suffix off.

## Traps already discovered (don't rediscover)

- **Zobrist init:** `Board::initHash()` is `call_once`-guarded, so both the
  engine (`MainCmds::gtp`) and `GoReplay` may call it. `GoReplay` does NOT call
  `ScoreValue::initTables()` (replay needs only rules), avoiding the single-init
  assertion clashing with the engine.
- **Capture-count fields are inverted vs their names:** Black's prisoners =
  `board.numWhiteCaptures`. Handled in `GoReplay.mm` — don't "fix" it.
- **GTP vertex mapping:** columns skip `I`; rows count from the bottom. Board
  coords are 0-indexed with y from the top. See `GtpCommandBuilder.vertex`.
- **kata-analyze winrate/scoreLead are White-perspective** (shipped cfg). Convert
  to side-to-move in `GameState.nnResult(from:)`.
- **default_gtp.cfg has `humanSL*` stripped:** no human-SL net is bundled, and
  the engine throws in `Setup::loadParams` if those keys are present without it.
- **Arbitrary setup positions load via `loadsgf`, not `set_position`.** The
  editor + photo import build a `SetupPosition` (both-color stones + side-to-move)
  and `GameState.syncEngineToRecord` writes a temp SGF and sends `loadsgf`.
  `set_position` can place both colors but *always forces Black to move*
  (`gtp.cpp` ~618), so it can't express White-to-play puzzles; `loadsgf` honors
  `AB`/`AW`/`PL`. `loadsgf` **aborts uncatchably without an `RU[...]` tag**, so
  the SGF codec always writes `RU[Chinese]`. `komi`/`kata-set-rule` after
  `loadsgf` preserve the loaded position, so app rules are re-applied on top. The
  temp path must be space-free (GTP splits the command on spaces). Validate a
  setup with `GoReplayKit.isPlaceableSetup` first (the engine rejects a
  zero-liberty group), else the engine keeps the old position while the UI shows
  the new one.
- **Tests are host-based** now (`@testable import GoLearner`, hosted by the app),
  so the engine's CoreML inference runs in a real app process (a hostless bundle
  crashes the NN-server threads).

---

## Where things live

| Task | File(s) |
|------|---------|
| Game logic / engine driving / state | `GoLearner/GameState.swift` (`@MainActor @Observable`) |
| GTP request/response coordination | `GoLearner/GameSession.swift` (`actor`) |
| GTP transport protocol / in-proc impl | `GoLearner/KataGoEngineIO.swift`, `Engine/Bridge/InProcessKataGoEngine.swift` |
| GTP command strings / analyze parser | `GoLearner/GtpCommandBuilder.swift`, `GoLearner/GtpAnalysisParser.swift` |
| Swift ⇄ engine GTP bridge (ObjC++) | `Engine/Bridge/KataGoGTP.{h,mm}` |
| Stateless board replay (ObjC++/Swift) | `Engine/Bridge/GoReplay.{h,mm}`, `GoLearner/GoReplayKit.swift` |
| CoreML/ANE + MLX/GPU backend (Swift) | `Engine/katago/KataGoSwift/metalbackend.swift` |
| Vendored KataGo engine (C++) | `Engine/katago/cpp/**` (pin in `Engine/katago/UPSTREAM.txt`) |
| Board UI + input | `GoLearner/BoardView.swift` |
| Analysis overlay | `GoLearner/AnalysisOverlay.swift` |
| Setup base (both-color stones + side-to-move) | `GoLearner/SetupPosition.swift` |
| Free board editor (puzzles) | `GoLearner/EditorBoard.swift` (pure), `GoLearner/BoardEditorView.swift` |
| Photo/camera position import | `GoLearner/Recognition/**` (`RecognizedBoard`, `BoardRecognizer`, `VisionBoardRecognizer`, `BoardImageAnalysis`, `PhotoImportView`, `CameraCaptureView`) |
| Project definition | `project.yml` (→ `xcodegen`) |
| Tests | `GoLearnerTests/` (host-based) |

## Definition of done (any change)
1. `xcodegen generate` (if files/settings changed).
2. Build succeeds (command 2).
3. `xcodebuild test` green (command 3).
4. For engine/feature changes: launch in sim, confirm the `selfCheck` genmove is
   a corner/star-point.

## Conventions
- Match KataGo semantics exactly for anything touching rules/GTP; cite the
  upstream source location in a comment when non-obvious.
- Keep changes surgical; don't refactor the vendored C++/Swift under
  `Engine/katago/`.
- Prefer extending the `GameSession`/`NNResult` seam over widening the ObjC++
  bridges.
- Post-P0 roadmap (downloadable nets, human-SL profiles, GTP console, photo
  import, sub-19 boards) is in [ROADMAP.md](ROADMAP.md); keep the `GameState`
  API stable when adding.
