---
name: swiftxstate-inspection
description: Visualize and debug SwiftXState machines — InspectionEvent stream, native inspector UI (SwiftXStateInspectorUI), statechart graphs (SwiftXStateGraph), Stately Inspector WebSocket bridge (InspectBridge), definitionJSON registration. Use when debugging machine behavior, adding an inspector window, graphing statecharts, or streaming actors to stately.ai.
---

# Inspection & visualization

Everything hangs off one stream: `InspectionEvent` (`.actor` registration / `.event` / `.snapshot`),
emitted by any actor with an `inspect:` observer. Three consumers ship with the library.

## 1. Raw stream (logging, metrics, custom tooling)

```swift
let actor = createActor(machine, inspect: { event in ... })    // @Sendable, hot path — keep O(1)
```

Fan out to several observers by composing closures (the `combineInspect` pattern in
`Examples/SwiftXChess/SwiftXChess/DistributedChessSession.swift`). `InspectionCollector` /
`InspectionRecorder` are ready-made sinks (recorder doubles as the replay source).

## 2. Native inspector UI (`SwiftXStateInspectorUI`, gate `SWIFTXSTATE_INSPECTOR_UI`)

Stately-Inspector-parity SwiftUI panel — actor list w/ state pills, Value+Context JSON trees,
chronological event feed, sequence diagram, live statechart graph. No network, works headless-dev:

```swift
let store = InspectorStore()                       // @MainActor @Observable ingester
let session = DistributedChessSession(extraInspect: store.observe())   // feed it any inspect stream
MachineInspectorView(store: store)                 // the window content
```

Handles high actor counts (the 96-board-actor stress test that kills the web client). Theme via
`InspectorStyle`; board-style grid layouts via `GraphStyle.nodeLayoutOverride` (see
`BoardInspectorMachine.gridLayoutOverride`).

## 3. Statechart graphs (`SwiftXStateGraph`)

```swift
await MachineGraphView(actor: session.actor, machine: session.machine)  // live actor + ResolvedMachine
StateGraphView(definitionJSON: json, machineID: id, stateValue: value)  // from definition JSON alone
```

2D Canvas + 3D SceneKit renderers, active-state highlighting, `GraphStyle` theming.

## 4. Stately Inspector bridge (`SwiftXStateInspect` + `SwiftXStateInspectURLSession`)

Streams actors to stately.ai's web inspector over WebSocket (`wireFormat: .stately`):

```swift
let transport = URLSessionInspect.transport(policy: .localhostOnly(ports: .only([8080])),
                                            runtime: InspectRuntimeContext(isDebugBuild: true))
let config = InspectClientConfiguration(
    policy: .localhostOnly(ports: .only([8080])),
    endpoint: InspectEndpoint(host: "127.0.0.1", port: 8080),
    runtime: InspectRuntimeContext(isDebugBuild: true),
    enablement: InspectEnablement(requiresDebugBuild: false, userOptIn: true),
    wireFormat: .stately,
    machineDefinitions: [try InspectMachineRegistration(machineId: M.id,
                                                        definitionJSON: M.resolved.definitionJSON())]
)
let bridge = InspectBridge(transport: transport, configuration: config)
await bridge.start()
let actor = createActor(machine, inspect: bridge.observe())   // wrap in do/catch; degrade gracefully
```

- `definitionJSON()` on any `ResolvedMachine` exports the XState-JSON chart.
- Register a compact **inspector-summary machine** for huge data-driven charts (the opening tree
  registers a 1-state summary with `wireStateValue`; runtime still runs the full tree).
- Security posture is explicit: localhost-only policy, debug-build runtime, user opt-in enablement.

## Choosing which actors stream

`inspectable:` per spawn / `ActorOptions.inspectable`. Orchestrators ON, fleets OFF — details and
cost model in swiftxstate-performance. `systemId` labels actor groups in the UIs.

## Reference files
- `Sources/SwiftXState/Inspection.swift` (event model), `MachineDefinition.swift` (definitionJSON/JSONValue)
- `Sources/SwiftXStateInspectorUI/`, `Sources/SwiftXStateGraph/`, `Sources/SwiftXStateInspect/`
- Wiring example: `Examples/SwiftXChess` (InspectorWindow, DistributedChessSession, SessionModel)
