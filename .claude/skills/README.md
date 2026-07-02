# SwiftXState agent skills

Skill modules for coding agents working with SwiftXState. Each `<skill>/SKILL.md` is self-contained
(frontmatter `description` is the routing trigger) and points into the real sources/tests/examples
for deeper reading. They live in the library repo so any agent session here loads them; app repos
using SwiftXState can copy or symlink this directory into their own `.claude/skills/`.

| Skill | Covers |
|---|---|
| swiftxstate-dsl | Authoring machines: StateMachine protocol, State/Transition builders, hierarchy/parallel, payload events, enq effects, data-driven machines |
| swiftxstate-transitions | Guards (context + event-aware), Always/choice, After delays, onDone, targets, RTC semantics |
| swiftxstate-actors | Multi-actor trees: enq.spawn, typed enq.sendTo with payloads, Invoke, child lifecycle, ids |
| swiftxstate-tasks | Async work: fromTask/fromTaskGroup/fromCallback/fromObservable, cancellation, progress |
| swiftxstate-swiftui | MainStore, @Machine, MachineView, bind() lens/prism, derived view state |
| swiftxstate-concurrency | Main-actor stores over background actors, Sendable rules, session objects, known crashers |
| swiftxstate-performance | inspectable ON/OFF, context design for hot paths, resolved-machine caching, event coalescing |
| swiftxstate-persistence | PersistedSnapshot hydration, SwiftData adapter, crash recovery |
| swiftxstate-undo-redo-replay | InspectionRecorder, timeTravel, verifyReplay, scrub UIs, recording gates |
| swiftxstate-inspection | InspectionEvent stream, native inspector UI, statechart graphs, Stately WebSocket bridge |
| swiftxstate-media-streaming | Player/recorder statecharts, AV-engine bridging, interruptions, transport UI |
| swiftxstate-testing | Non-flaky async tests, waitForSnapshot, mirror structural tests, replay verification |
