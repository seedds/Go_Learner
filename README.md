# GoLearner

An iPhone Go (囲碁 / 바둑) app powered by the **full KataGo engine** running
in-process, with neural-net inference on the **Apple Neural Engine** (Core ML)
and an **MLX/GPU** path on device.

Play against a strong AI, watch it analyze the position live (win rate, score
lead, territory ownership, candidate moves), and step through your game — all
on-device, offline.

> Status: **P0 engine pivot shipped.** The app embeds the complete KataGo engine
> and drives it over GTP (real MCTS search, native rules/SGF, MLX + CoreML mux),
> instead of the earlier hand-ported NN slice. Builds and runs on the iOS 26
> simulator (runtime self-check opens on a corner/star-point, 114 tests green).
> Since P0, sub-19 boards and photo/camera position import have landed too. See
> [ROADMAP.md](ROADMAP.md) for what's next (downloadable nets, human-style
> profiles, GTP console).

---

## What it is

GoLearner is a lean, single-target iPhone app built fresh (not a fork). It
reuses the proven parts of the KataGo engine where correctness matters and
keeps everything else small and modern SwiftUI.

- **Real KataGo strength.** Moves and analysis come from the *actual* KataGo
  engine (full MCTS search), running the official 18-block `b18c384nbt` network.
- **Apple-silicon inference.** The `.bin.gz` net is converted to Core ML at
  launch and run on the ANE; on device an MLX/GPU + ANE mux adds throughput.
- **Correct Go rules & everything else — from KataGo itself.** Rules, ko/superko,
  scoring, search, and native SGF are the vendored KataGo C++ engine, driven over
  GTP. Offline board rendering/review uses the same rules via a stateless replay
  bridge (`GoReplay`).
- **Offline & private.** The model is bundled in the app; nothing leaves the
  device.

### Scope today

- 9×9 / 13×13 / 19×19 boards, configurable komi, area/territory + ko rules.
- Human vs AI, AI vs AI, or Human vs Human (tap a player capsule to toggle).
- Full MCTS search per move via the embedded engine (time-bounded; the AI
  thinking-time budget is a Settings knob).
- Live analysis overlay from `kata-analyze`: win rate, score lead, ownership
  shading, and top candidate moves with per-move win% + visits.
- Move navigation + win-rate bar (tap a past position to branch a new line),
  SGF import/export, SwiftData game library, rules/komi + player setup,
  handicap, GIF export, pass, new game.
- Set an arbitrary position: a free board editor and photo/camera import
  (whole board or a cropped fragment), for puzzles and studying real games.
- Light / dark / system theme.

### Not present yet (post-P0 roadmap)

- Downloadable networks, human-style (human-SL) profiles, a GTP console,
  a backend picker + CoreML cache UI.
- iCloud sync.
- Learning features (tsumego, guided "why this move") — the namesake direction.

---

## How it works (30-second version)

```
 SwiftUI (ContentView / BoardView / AnalysisOverlay)
        │  reads
        ▼
 GameState  ── move-list record ──►  GoReplay (ObjC++)   ← stateless rules:
   (@MainActor,                         board / review / GIF / thumbnails
    @Observable)
        │ drives (play / genmove / kata-analyze)
        ▼
 GameSession (actor) ─► KataGoEngineIO ─► KataGoGTP (ObjC++) ─► KataGo engine
        ▲                                   (in-process GTP loop)   │
        └──── NNResult / GtpAnalysis ◄── GtpAnalysisParser ◄────────┘
                                              MLX/GPU + CoreML/ANE inference
```

- The **engine runs in-process over GTP** (one engine per process): `KataGoGTP`
  rebinds its `cout`/`cin` to thread-safe buffers on a dedicated 8 MB-stack
  thread; `GameSession` serializes command/response traffic.
- **Live play/analysis** go to the engine; **offline board reconstruction**
  (rendering, review, GIF, thumbnails) replays the Swift move-list through the
  stateless `GoReplay` bridge — never touching the single engine.
- Inference converts the `.bin.gz` net to Core ML at launch (CoreML/ANE), with an
  MLX/GPU + ANE mux on device.

See **[ARCHITECTURE.md](ARCHITECTURE.md)** for the full map.

---

## Project layout

```
GoLearner/
├── README.md                     ← you are here
├── ARCHITECTURE.md               ← deep dive for developers / AI agents
├── project.yml                   ← XcodeGen spec (generates the .xcodeproj)
├── Resources/
│   ├── default_model.bin.gz      ← bundled KataGo net (b18c384nbt, ~93 MB)
│   └── default_gtp.cfg           ← engine config (humanSL* stripped)
├── Engine/
│   ├── Bridge/                   ← Swift ⇄ engine seams (ObjC++)
│   │   ├── KataGoGTP.{h,mm}      ← in-process GTP loop (rebinds cout/cin)
│   │   ├── GoReplay.{h,mm}       ← stateless move-list → board (KataGo rules)
│   │   ├── GoTypes.h             ← GoColor (engine-independent)
│   │   ├── InProcessKataGoEngine.swift  ← launches + relays to the engine
│   │   └── GoLearner-Bridging-Header.h
│   └── katago/                   ← vendored full KataGo engine (see UPSTREAM.txt)
│       ├── cpp/**                ← core/game/search/neuralnet/dataio/… + externals
│       ├── KataGoSwift/          ← Swift⇄C++ CoreML/MLX backend
│       └── ThirdParty/mlx-swift/ ← vendored MLX
└── GoLearner/                    ← the SwiftUI app target
    ├── GoLearnerApp.swift        ← @main entry (SwiftData container)
    ├── RootView.swift            ← Play / History / Settings tabs + autosave
    ├── ContentView.swift         ← Play screen: capsules, board, controls
    ├── BoardView.swift           ← goban rendering + tap input
    ├── AnalysisOverlay.swift     ← ownership + candidate-move overlay
    ├── GameState.swift           ← @MainActor @Observable model (the brain)
    ├── GameSession.swift         ← actor: serializes GTP traffic
    ├── GtpCommandBuilder.swift   ← Config → GTP command strings
    ├── GtpAnalysisParser.swift   ← kata-analyze → candidates/ownership/root
    ├── GoReplayKit.swift         ← Swift facade over GoReplay
    ├── SGF.swift                 ← SGF codec (setup stones + PL + result)
    ├── SetupPosition.swift       ← pre-move base (both-color stones + turn)
    ├── SavedGame.swift           ← SwiftData model (SGF is source of truth)
    ├── LibraryView / NewGameView / SettingsView / AppTheme.swift
    ├── EditorBoard + BoardEditorView.swift  ← free board editor (puzzles)
    ├── GameGIF + GIFExportView.swift        ← animated-GIF export
    └── Recognition/             ← photo/camera position import (Vision + CI)
```

---

## Build

Requirements: macOS with **Xcode 26+** (iOS 26 SDK), Apple silicon recommended.
The first build needs the **Metal Toolchain** (MLX compiles Metal kernels):
`xcodebuild -downloadComponent MetalToolchain` once, if you see
`cannot execute tool 'metal'`.

The KataGo net + config are already in `Resources/`. The `.xcodeproj` is
generated from `project.yml` with [XcodeGen](https://github.com/yonaskolb/XcodeGen)
(`brew install xcodegen`).

```bash
cd GoLearner
xcodegen generate          # produces GoLearner.xcodeproj
open GoLearner.xcodeproj   # or build from the command line:

xcodebuild build \
  -project GoLearner.xcodeproj \
  -scheme GoLearner \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

> Set your development team in *Signing & Capabilities* to run on a device.

---

## Credits

- **KataGo** by David Wu (lightvector) — the engine and neural networks.
  <https://github.com/lightvector/KataGo>
- **KataGo Core ML / iOS work** by Chin-Chang Yang, whose `ios-dev` fork
  provided the Core ML model export and the reference for the input/output
  contract. <https://github.com/ChinChangYang/KataGo>

The bundled network and the vendored C++ are licensed under KataGo's license.
