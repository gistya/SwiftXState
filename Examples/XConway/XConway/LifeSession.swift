import Foundation
import SwiftUI
import SwiftXState
import SwiftData
import SwiftXStateSwiftData

/// Synchronous, `Store`-backed bridge between SwiftUI and the Game of Life state.
///
/// This variant deliberately does **not** use the async `Actor`. SwiftXState's `Store` is a plain
/// `final class` with its own synchronous transition engine (no executor, no `await`). Held on the
/// `@MainActor`, `store.send(event)` runs the reducer inline on the main thread and returns, so the
/// new snapshot is readable — and the grid repaints — in the *same* runloop turn as the gesture.
/// That removes the actor round-trip latency entirely, which is why there is no optimistic mirror and
/// no prediction here: the UI reads the real source of truth, synchronously.
///
/// The tradeoff is that the reducer (including `nextGeneration`) runs on the main thread. For Life's
/// default grid that's sub-millisecond per step; for a much larger grid you'd want the async actor (or
/// a background store) so stepping doesn't block the UI.
@MainActor
@Observable
public final class LifeSession {
    private let store: Store<LifeContext, LifeEvent>
    private let modelContext: ModelContext?
    // Distinct from the actor key so the two example variants don't fight over one persisted blob.
    private let persistenceKey = "xconway.life.store.v1"

    public private(set) var snapshot: StoreSnapshot<LifeContext>
    public var context: LifeContext { snapshot.context }

    public var rulesJSON: String = LifeRules.conway.jsonString
    private var lastStepTime: Date = .distantPast
    public private(set) var history: [GridSnapshot] = []
    public var isReplayMode = false
    public var replayIndex = 0

    // We only grow the full replay history after the user has paused at least once.
    // This prevents huge history arrays (and associated copies) during long unattended runs.
    private var replayRecordingEnabled = false

    /// The context that should be rendered (either live or a historical snapshot).
    public var displayContext: LifeContext {
        if isReplayMode, replayIndex < history.count {
            let snap = history[replayIndex]
            var dc = context
            dc.cells = snap.cells
            dc.generation = snap.generation
            return dc
        }
        return context
    }

    public init(modelContext: ModelContext? = nil) {
        self.modelContext = modelContext
        let initial = Self.loadContext(modelContext: modelContext, key: persistenceKey) ?? .empty()
        self.store = LifeStoreFactory.make(context: initial)
        self.snapshot = store.snapshot
        self.history = [GridSnapshot(generation: initial.generation, cells: initial.cells)]
        self.rulesJSON = initial.rules.jsonString
        self.interval = 1.0 / max(0.5, initial.speed)
    }

    // MARK: - Send (fully synchronous)

    public func send(_ event: LifeEvent) {
        // Synchronous: mutate the store and read the new snapshot inline — no await, same frame.
        store.send(event)
        snapshot = store.snapshot

        // Keep the rules editor in sync (covers SET_RULES_JSON and any internal rule change).
        let currentRules = context.rules.jsonString
        if rulesJSON != currentRules {
            rulesJSON = currentRules
        }

        recordHistory(for: event)

        if case .restore = event {
            isReplayMode = false
        }
        if case .setSpeed(let speed) = event {
            interval = 1.0 / max(0.5, speed)
        }
    }

    private func recordHistory(for event: LifeEvent) {
        switch event {
        case .pause:
            scrub(to: Int.max)
        case .step:
            let c = context
            appendToHistory(GridSnapshot(generation: c.generation, cells: c.cells))

        case .clear, .randomize:
            let c = context
            history = [GridSnapshot(generation: c.generation, cells: c.cells)]
            isReplayMode = false
            replayIndex = 0

        case .restore(let saved):
            let snap = GridSnapshot(generation: saved.generation, cells: saved.cells)
            if history.isEmpty || history.last?.generation != snap.generation {
                history = [snap]
            }
            replayIndex = 0

        case .loadTemplate, .toggleCell:
            // Live edits update the "present" head of the timeline when not replaying
            if !isReplayMode {
                let c = context
                let snap = GridSnapshot(generation: c.generation, cells: c.cells)
                if !history.isEmpty {
                    history[history.count - 1] = snap
                } else {
                    history = [snap]
                }
            }

        default:
            break
        }
    }

    private func appendToHistory(_ snap: GridSnapshot) {
        if !replayRecordingEnabled && history.count >= 5000 {
            history.removeFirst()
        }

        history.append(snap)

        let maxEntries = 5000
        if history.count > maxEntries {
            let drop = history.count - maxEntries
            history.removeFirst(drop)
        }

        if isReplayMode {
            replayIndex = history.count - 1
        }
    }

    // MARK: - Commands (called from UI) — all synchronous

    public func toggleCell(x: Int, y: Int) { send(.toggleCell(x: x, y: y)) }
    public func step() {
        lastStepTime = Date()
        send(.step)
    }
    public func play() {
        isReplayMode = false
        send(.play)
        lastStepTime = Date()
        step()
        startTimer()
    }

    public func pause() {
        stopTimer()
        send(.pause)
        replayRecordingEnabled = true
    }
    public func clear() {
        send(.clear)
    }

    public func randomize(density: Double = 0.28) {
        send(.randomize(density: density))
    }

    public func loadTemplate(_ name: String, atX: Int? = nil, atY: Int? = nil) {
        send(.loadTemplate(name: name, atX: atX, atY: atY))
    }

    public func applyRulesFromJSON(_ json: String) {
        guard LifeRules.from(json: json) != nil else { return }
        send(.setRulesJSON(json))
    }

    private var interval = 1.0 / 60.0

    public func setSpeed(_ s: Double) {
        send(.setSpeed(s))
    }

    private var timerTask: Task<Void, Never>? = nil

    // MARK: - Autoplay loop
    //
    // `step()` is synchronous, so the loop simply steps then sleeps. Each step finishes before the next
    // is scheduled — no backlog can form, and cancelling stops it immediately. (The step's compute runs
    // on the main thread; fine for Life's default grid.)

    private func startTimer() {
        timerTask?.cancel()
        timerTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                self.step()
                try? await Task.sleep(for: .seconds(self.interval))
            }
        }
    }

    private func stopTimer() {
        timerTask?.cancel()
        timerTask = nil
    }

    // MARK: - Persistence (LifeContext is Codable; stored via the registered ActorSnapshotRecord model)

    private static func loadContext(modelContext: ModelContext?, key: String) -> LifeContext? {
        guard let mc = modelContext else { return nil }
        var descriptor = FetchDescriptor<ActorSnapshotRecord>(predicate: #Predicate { $0.key == key })
        descriptor.fetchLimit = 1
        guard let record = try? mc.fetch(descriptor).first else { return nil }
        return try? JSONDecoder().decode(LifeContext.self, from: record.snapshotData)
    }

    private func saveContextSnapshot() {
        guard let mc = modelContext else { return }
        guard let data = try? JSONEncoder().encode(context) else { return }
        let key = persistenceKey
        var descriptor = FetchDescriptor<ActorSnapshotRecord>(predicate: #Predicate { $0.key == key })
        descriptor.fetchLimit = 1
        if let existing = try? mc.fetch(descriptor).first {
            existing.snapshotData = data
            existing.machineId = "life"
            existing.updatedAt = .now
        } else {
            mc.insert(ActorSnapshotRecord(key: key, machineId: "life", snapshotData: data))
        }
        try? mc.save()
    }

    public func saveSnapshot() { saveContextSnapshot() }
    public func saveNow() { saveSnapshot() }
    public func forceSave() { saveContextSnapshot() }

    // MARK: - Replay bar API (available when paused) — all synchronous

    public func scrub(to index: Int) {
        guard !history.isEmpty else { return }
        isReplayMode = true
        let scrubTo: Int
        if index > history.count - 1 { scrubTo = history.count - 1 }
        else { scrubTo = index }
        replayIndex = max(0, min(scrubTo, history.count - 1))
    }

    public func exitReplay() {
        isReplayMode = false
    }

    public func restoreFromReplay() {
        guard isReplayMode, !history.isEmpty, replayIndex < history.count else { return }
        let snap = history[replayIndex]
        history = Array(history.prefix(replayIndex + 1))

        var restored = context
        restored.cells = snap.cells
        restored.generation = snap.generation

        stopTimer()
        send(.restore(restored))
        send(.pause)  // ensure we land in paused state
        isReplayMode = false
        replayIndex = max(0, history.count - 1)
    }

    deinit {
        // timerTask captures self weakly; it unwinds on its own once the session is gone.
    }
}

// MARK: - Store factory (synchronous reducers — mirrors LifeMachineFactory's assigns 1:1)

enum LifeStoreFactory {
    static func make(context: LifeContext) -> Store<LifeContext, LifeEvent> {
        let on: [String: StoreMutator<LifeContext, LifeEvent>] = [
            "TOGGLE_CELL": { ctx, evt in
                if case .toggleCell(let x, let y) = evt { ctx[x, y].toggle() }
            },
            "STEP": { ctx, _ in
                ctx.cells = nextGeneration(cells: ctx.cells, width: ctx.width, height: ctx.height, rules: ctx.rules)
                ctx.generation += 1
            },
            "CLEAR": { ctx, _ in
                ctx.reset()
            },
            "RANDOMIZE": { ctx, evt in
                var density = 0.28
                if case .randomize(let d) = evt { density = d }
                let count = ctx.width * ctx.height
                ctx.cells = (0..<count).map { _ in Double.random(in: 0...1) < density }
                ctx.generation = 0
            },
            "LOAD_TEMPLATE": { ctx, evt in
                guard case .loadTemplate(let name, let atX, let atY) = evt,
                      let tmpl = LifeTemplate(rawValue: name) else { return }
                let offsets = tmpl.cells
                let baseX = atX ?? (ctx.width / 2 - 8)
                let baseY = atY ?? (ctx.height / 2 - 6)
                for (ox, oy) in offsets {
                    let x = (baseX + ox + ctx.width) % ctx.width
                    let y = (baseY + oy + ctx.height) % ctx.height
                    ctx[x, y] = true
                }
            },
            "SET_RULES_JSON": { ctx, evt in
                if case .setRulesJSON(let json) = evt, let parsed = LifeRules.from(json: json) {
                    ctx.rules = parsed
                }
            },
            "SET_SPEED": { ctx, evt in
                if case .setSpeed(let s) = evt { ctx.speed = max(0.5, min(60.0, s)) }
            },
            "PLAY": { ctx, _ in ctx.isPlaying = true },
            "PAUSE": { ctx, _ in ctx.isPlaying = false },
            "RESTORE": { ctx, evt in
                if case .restore(let saved) = evt { ctx = saved }
            },
        ]
        return createStore(context: context, on: on)
    }
}
