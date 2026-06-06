# SwiftXChess

A macOS SwiftUI sample that plays chess on top of a **SwiftXState** state machine. The app is structured so you can copy the same pattern into your own projects: define a machine, wrap it in a small session object, and bind SwiftUI views to `snapshot` / `context`.

## Foreword

**Note to the reader:** "Actor" here means a `SwiftXState.Actor` — not a Swift concurrency `actor`. SX's type names are kept as consistent as possible with the original XState for the sake of harmony. 

(For details on using the Swift concurrency support built into SX, see the main README.md.)

## What SwiftXChess demonstrates

| Concern | Where it lives |
|--------|----------------|
| Game rules (legal moves, checkmate, promotion) | `ChessRules.swift` |
| **When** moves are allowed, replay mode, game-over flow | `ChessMachine.swift` + `ChessCastlingMachine.swift` |
| Castling rights as explicit parallel regions | `ChessCastlingMachine.swift` |
| SwiftUI wiring | `ChessSession.swift` → `ContentView.swift` → `ChessBoardView.swift` |
| DevTools recording + replay scrubber | `ChessSession.swift`, `ChessReplayRestore.swift` |
| Stately live inspector | `ChessSession.makeInspectBridge` |

The machine owns **orchestration** (states, guards, which handlers run). `ChessRules` owns **domain logic** (whether a tap is a legal move). Views never call `ChessRules` directly.

## Architecture

```mermaid
flowchart LR
    subgraph swiftui [SwiftUI]
        CV[ContentView]
        CBV[ChessBoardView]
    end

    subgraph bridge [Bridge layer]
        CS[ChessSession]
    end

    subgraph runtime [SwiftXState]
        Actor[Actor of ChessContext]
        SM[StateMachine from ChessMachineFactory]
    end

    CV -->|reads context / snapshot| CS
    CBV -->|onTap / onPromote| CS
    CS -->|send ChessEvent| Actor
    Actor --> SM
    SM -->|assign updates| Actor
    Actor -->|snapshot| CS
    CS -->|@Observable refresh| CV
```

**One-way command flow:** UI → `ChessSession.send` → `actor.send` → transition → `assign` mutates `ChessContext` → `snapshot` updates → SwiftUI re-renders.

**One-way read flow:** Views read `session.context` (and sometimes `session.snapshot.value` for machine state strings).

## The three machine inputs

### 1. Context — `ChessContext` (`ChessTypes.swift`)

Everything the UI needs to draw the board lives in context:

- `board`, `turn`, `selected`, `pendingPromotion`, `moveHistory`, `outcome`
- Replay fields: `replaySession`, `replayStep`, `liveSnapshot`
- Derived helpers: `isReplayMode`, `statusLine`

Initial state: `ChessContext.initial()`.

The machine config references the same shape:

```swift
// ChessMachineFactory.build()
context: ChessContext.initial(),
```

### 2. Events — `ChessEvent` (`ChessTypes.swift`)

User and system actions are typed events conforming to `Eventable`. Each event exposes an XState-style `type` string the machine matches on:

| Swift enum case | `type` string | Typical source |
|-----------------|---------------|----------------|
| `.tap(square)` | `TAP.{row}.{col}` | `ChessBoardView` tap |
| `.promote(kind)` | `PROMOTE.{kind}` | promotion picker |
| `.newGame` | `NEW_GAME` | sidebar button |
| `.enterReplay` | `ENTER_REPLAY` | sidebar button |
| `.exitReplay` | `EXIT_REPLAY` | sidebar button |
| `.replayScrub(step)` | `REPLAY_SCRUB.{step}` | replay slider |

Wildcard handlers in the machine use patterns like `"TAP.*"` and `"PROMOTE.*"`.

### 3. Machine — `ChessMachineFactory` (`ChessMachine.swift`)

Built with `createMachine(MachineConfig(...))` and cached as `ChessMachineFactory.machine`.

**Parallel root** — two regions run at once:

- `game` — compound: `playing` | `gameOver` | `replaying`
- `castling` — parallel sub-regions for each castling right (`available` / `forfeited`)

Example: a tap in `playing` runs **two** things in parallel:

1. `assign { handleTap }` updates the board in context (`ChessMachine.handleTap` → `ChessRules.handleTap`)
2. Castling guards may transition a `castling.*` region to `forfeited` without touching the board

**Automatic game-over:** `playing` has an `always` transition to `gameOver` when guard `hasOutcome` is true (registered via `setup(guards:)`).

## `ChessSession` — the SwiftUI bridge

`ChessSession` (`ChessSession.swift`) is the only object views should talk to. It is `@MainActor` and `@Observable`.

### Bootstrapping the actor

```swift
let machine = ChessMachineFactory.machine
actor = createActor(machine, options: ActorOptions(inspect: inspect))
snapshot = actor.start(context: ChessContext.initial()).snapshot
```

- `createActor` comes from **SwiftXState**.
- `inspect` fans out to `InspectionRecorder` (for replay) and optionally `InspectBridge` (Stately).
- After `start`, `snapshot` holds the current `MachineSnapshot<ChessContext>`.

### Sending events

All UI commands funnel through `send(_:)`:

```swift
func send(_ event: ChessEvent) {
    actor.send(event)
    snapshot = actor.snapshot
}
```

Higher-level helpers wrap typed events:

- `tap(row:col:)` → `.tap(Square(...))`
- `promote(to:)` → `.promote(kind)`
- `newGame()` → `.newGame`
- `enterReplay()` / `exitReplay()` / `scrubReplay(to:)`

**Important:** `snapshot` is updated synchronously on the main actor immediately after `actor.send`. Views depend on this — do not defer snapshot updates to an async subscriber if you want the canvas to stay in sync.

### Reading state in views

```swift
var context: ChessContext { snapshot.context }
```

Views use `session.context` for **data** and `session.snapshot.value` for **machine state** (e.g. the sidebar shows `session.snapshot.value.description` and derives castling summary from `CastlingRights(stateValue: session.snapshot.value)`).

## How SwiftUI hooks in

### Owning the session (`ContentView.swift`)

```swift
@State private var session = ChessSession()

var body: some View {
    @Bindable var session = session
    // ...
}
```

`@State` creates one session per window. `@Bindable` lets SwiftUI observe `@Observable` property changes on `ChessSession`.

### Board: read context, send commands (`ContentView` → `ChessBoardView`)

The board is a **dumb** view: props in, callbacks out.

```swift
ChessBoardView(
    board: session.context.board,
    selected: session.context.selected,
    pendingPromotion: session.context.pendingPromotion,
    promotionColor: session.context.turn,
    isInteractive: !session.context.isReplayMode && session.context.outcome == nil,
    onTap: { row, col in session.tap(row: row, col: col) },
    onPromote: { kind in session.promote(to: kind) }
)
```

- **Read path:** `session.context.*` drives piece positions, selection highlight, promotion UI.
- **Write path:** taps call `session.tap`, which becomes a machine event.
- **Gating:** `isInteractive` uses context flags the machine maintains (`isReplayMode`, `outcome`). The machine also ignores taps in `handleTap` when `replaySession != nil`.

### Sidebar: machine state + replay (`ContentView`)

| UI element | Source |
|------------|--------|
| Status line | `session.context.statusLine` |
| Move count | `session.context.moveHistory.count` |
| State string | `session.snapshot.value.description` |
| Castling diagram | `CastlingRights(stateValue: session.snapshot.value)` |
| Enter replay button | `session.canReplay` (recorder has >1 step) |
| Replay slider | visible when `session.context.isReplayMode`; calls `session.scrubReplay(to:)` |

Replay flow:

1. `enterReplay()` — freezes `InspectionRecorder.session()`, disables further recording, passes session through `ChessReplayBridge`, sends `ENTER_REPLAY`.
2. Machine action `enterReplay` stores session on context and restores step 0 via `syncReplaySnapshot`.
3. Slider sends `REPLAY_SCRUB.{n}`; `scrubReplay` restores board from recorded snapshots (`ChessReplayRestore.apply`).

## What happens on a tap (end-to-end)

1. User taps a square in `ChessBoardView` → `onTap(row, col)`.
2. `ContentView` calls `session.tap(row:col:)`.
3. `ChessSession.send(.tap(Square(row:col:)))`.
4. `Actor.send` runs `selectTransitions` for event type `TAP.{row}.{col}`.
5. Matching transitions fire `assign` actions:
   - `ChessMachine.handleTap` parses event, calls `ChessRules.handleTap(&context, at:)`.
   - Castling region may transition if parameterized `forfeitsCastling` guard passes for that side.
6. If `context.outcome` is set, `always` may move `game` → `gameOver`.
7. `actor.snapshot` updates; `ChessSession.snapshot` copies it.
8. SwiftUI re-reads `session.context.board`, `selected`, `turn`, etc.

Promotion follows the same path with `PROMOTE.{kind}` → `handlePromotion` → `ChessRules.handlePromotion`.

## Adapting this pattern to your app

### Minimal recipe

1. **Define `MyContext`** — single struct with all UI-facing data.
2. **Define `MyEvent: Eventable`** — enum with `var type: String` matching machine `on` keys.
3. **Build `MyMachineFactory.machine`** with `createMachine`.
4. **Create `MySession`** (`@MainActor @Observable`):
   - `let actor: Actor<MyContext>`
   - `private(set) var snapshot: MachineSnapshot<MyContext>`
   - `var context: MyContext { snapshot.context }`
   - `func send(_ event: MyEvent) { actor.send(event); snapshot = actor.snapshot }`
5. **Views** — `@State private var session = MySession()`, read `session.context`, call `session.send` or thin wrappers.

### Separation of concerns

| Do in machine `assign` / guards | Do in plain Swift (e.g. `ChessRules`) |
|----------------------------------|----------------------------------------|
| Mode switches (playing / replay / game over) | Move legality, check detection |
| Which events are accepted in which state | Board mutation algorithms |
| Parallel regions for orthogonal concerns | Formatting strings for display (can also live on context) |

Keep views free of `createActor`, `StateMachine`, and `assign`. They should only see `MySession`.

### When to read `snapshot.value` vs `context`

- **`context`** — application data you control in `assign` (board, form fields, lists).
- **`snapshot.value`** — current state node path (`game.playing`, `castling.whiteKingside.available`, …). Use when the UI needs to reflect **machine structure**, not just data.

## Running the app

1. Open `SwiftXChess.xcodeproj` in Xcode.
2. Run the **SwiftXChess** scheme (macOS).

### Optional: Stately live graph

From `Scripts/relay`:

```bash
npm install && npm run relay
```

Open the `https://stately.ai/registry/inspect/…` URL printed in the terminal, then run the app. The sidebar **Stately Inspector** card shows connection status.

### Xcode previews

`ChessBoardPreviews.swift` provides canvas previews for the board (starting position, selection, promotion picker, interactive taps, and all piece assets). Use **Editor → Canvas** while editing `ChessBoardView` or `ChessPieceView`.

## Project layout

The app target holds the chess engine + UI. The **opening-recognition** engine is split into a
small local Swift package, `SwiftXChessOpenings/`, purely so its pure-logic tests can run under
`swift test` instead of an app test bundle. The Xcode project links that package as a local
dependency; it in turn depends on the main `swift-xstate` package at the repo root.

```
Examples/SwiftXChess/
├── SwiftXChess.xcodeproj
├── SwiftXChess/                      # App target — engine + UI
│   ├── SwiftXChessApp.swift          # App entry → ContentView
│   ├── ContentView.swift             # Session owner; binds context to views
│   ├── ChessSession.swift            # Actor + snapshot bridge; inspect + replay
│   ├── DistributedChessSession.swift # Multi-actor (board) session + inspector wiring
│   ├── ChessMachine.swift            # Main state machine + assign handlers
│   ├── ChessCastlingMachine.swift    # Parallel castling region
│   ├── ChessTypes.swift / ChessTypedState.swift  # Context, events, board model
│   ├── ChessRules.swift              # Pure chess logic (called from machine)
│   ├── ChessSAN.swift                # SAN encoding
│   ├── ChessReplayRestore.swift      # Snapshot restore for replay scrub
│   ├── BoardActors/                  # Square / Piece / GameWatcher / BoardInspector actors
│   ├── ChessBoardView.swift / ChessPieceView.swift / ChessBoardPreviews.swift  # Board UI
│   └── OpeningDemo*/OpeningPanelView.swift  # Opening-tree demo UI
│
└── SwiftXChessOpenings/              # Local Swift package — opening recognition only
    ├── Package.swift                 # depends on ../../.. (swift-xstate) + chesskit-swift
    ├── Sources/SwiftXChessOpenings/  # OpeningMoveTreeMachine, recognition, transposition DAG
    └── Tests/                        # swift test → 13 tests, 4 suites
```

Run the openings engine on its own: `cd SwiftXChessOpenings && swift test`.

## Dependencies

The app target links:

- **SwiftXChessOpenings** — the local opening-recognition package
- **SwiftXState** — `createMachine`, `createActor`, `Actor`, `assign`, replay APIs
- **SwiftXStateSwiftUI** — available for additional helpers (this sample uses manual `@Observable` bridging)
- **SwiftXStateInspect** / **SwiftXStateInspectURLSession** — Stately WebSocket bridge

`SwiftXChessOpenings/Package.swift` declares the package's own dependencies: the main `swift-xstate`
package (`.package(path: "../../..")`) and `chesskit-swift`. The machine definition is registered for
inspection via `InspectMachineRegistration(machine)` so the live graph matches the running app.
