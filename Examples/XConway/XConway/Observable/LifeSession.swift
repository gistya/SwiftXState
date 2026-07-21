import Foundation
import SwiftUI
import SwiftXState
import SwiftXStateSwiftUI
import SwiftData
import SwiftXStateSwiftData

/// The app's view model, rebuilt on the Plan-D typed DSL.
///
/// It owns a `MainStore` — the `@MainActor` membrane that collates typed actors on the main actor —
/// and tracks the typed `LifeMachine` in it. The live grid is read reactively from the tracked
/// `MachineStore<LifeMachine>` (`life.context`), and commands send **typed** events to the machine's
/// actor. `nextGeneration` therefore runs off the main thread (on the actor), which is what the old
/// synchronous-`Store` note recommended for larger grids; the only cost is a ~frame of display
/// latency, invisible in practice.
///
/// History/replay and SwiftData persistence are layered on top here, in the view model — the machine
/// stays a pure interpreter of events.
@MainActor
@Observable
public final class LifeSession {
    /// The main-actor membrane. Public so a debug/inspector view could read `store.all`.
    public let store = MainStore()

    @ObservationIgnored private let life: MachineStore<LifeMachine>
    @ObservationIgnored private let modelContext: ModelContext?
    private let persistenceKey = "xconway.life.store.v2"   // v2: distinct from the old Store blob

    /// The live context (reactive — `life` is `@Observable`).
    public var context: LifeContext { life.context }

    public var rulesJSON: String
    public private(set) var history: [GridSnapshot]
    public var isReplayMode = false
    public var replayIndex = 0
    private var replayRecordingEnabled = false

    @ObservationIgnored private var interval = 1.0 / 12.0
    @ObservationIgnored private var timerTask: Task<Void, Never>?

    /// What the grid should render — live, or a historical snapshot while scrubbing.
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
        self.life = store.track(LifeMachine())

        let restored = Self.loadContext(modelContext: modelContext, key: persistenceKey)
        let seed = restored ?? .empty()
        self.rulesJSON = seed.rules.jsonString
        self.history = [GridSnapshot(generation: seed.generation, cells: seed.cells)]
        self.interval = 1.0 / max(0.5, seed.speed)

        // Hydrate the machine from the persisted grid (the declared initial context is empty).
        if let restored {
            let actor = life.actor
            Task { @MainActor in await actor.send(.restore(restored)) }
        }
    }

    // MARK: - Commands (typed events → the machine's actor)

    public func toggleCell(x: Int, y: Int) { sendAndRecord(.toggleCell(x: x, y: y)) }
    public func step() { sendAndRecord(.step) }
    public func clear() { sendAndRecord(.clear) }
    public func randomize(density: Double = 0.28) { sendAndRecord(.randomize(density: density)) }
    public func loadTemplate(_ name: String, atX: Int? = nil, atY: Int? = nil) {
        sendAndRecord(.loadTemplate(name: name, atX: atX, atY: atY))
    }

    public func applyRulesFromJSON(_ json: String) {
        guard LifeRules.from(json: json) != nil else { return }
        sendAndRecord(.setRulesJSON(json))
    }

    public func setSpeed(_ s: Double) {
        interval = 1.0 / max(0.5, s)
        sendAndRecord(.setSpeed(s))
    }

    public func play() {
        isReplayMode = false
        let actor = life.actor
        Task { @MainActor in await actor.send(.play) }
        startTimer()
    }

    public func pause() {
        stopTimer()
        let actor = life.actor
        Task { @MainActor in await actor.send(.pause) }
        replayRecordingEnabled = true
        scrub(to: Int.max)
    }

    /// Send a typed event, then read the resulting context (typed) to keep history + the rules editor
    /// in sync. The send + read are awaited on the actor so history is recorded against the real
    /// post-transition state.
    private func sendAndRecord(_ event: LifeEvent) {
        let actor = life.actor
        Task { @MainActor [weak self] in
            await actor.send(event)
            let ctx = await actor.context
            guard let self else { return }
            if self.rulesJSON != ctx.rules.jsonString { self.rulesJSON = ctx.rules.jsonString }
            self.recordHistory(for: event, context: ctx)
        }
    }

    // MARK: - Autoplay (each step awaits the actor → no backlog; compute runs off main)

    private func startTimer() {
        timerTask?.cancel()
        timerTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let actor = self.life.actor
            while !Task.isCancelled {
                await actor.send(.step)
                let ctx = await actor.context
                self.recordHistory(for: .step, context: ctx)
                try? await Task.sleep(for: .seconds(self.interval))
            }
        }
    }

    private func stopTimer() {
        timerTask?.cancel()
        timerTask = nil
    }

    // MARK: - History / replay

    private func recordHistory(for event: LifeEvent, context c: LifeContext) {
        switch event {
        case .step:
            appendToHistory(GridSnapshot(generation: c.generation, cells: c.cells))
        case .clear, .randomize:
            history = [GridSnapshot(generation: c.generation, cells: c.cells)]
            isReplayMode = false
            replayIndex = 0
        case .restore(let saved):
            let snap = GridSnapshot(generation: saved.generation, cells: saved.cells)
            if history.isEmpty || history.last?.generation != snap.generation { history = [snap] }
            replayIndex = 0
        case .loadTemplate, .toggleCell:
            if !isReplayMode {
                let snap = GridSnapshot(generation: c.generation, cells: c.cells)
                if !history.isEmpty { history[history.count - 1] = snap } else { history = [snap] }
            }
        default:
            break
        }
    }

    private func appendToHistory(_ snap: GridSnapshot) {
        if !replayRecordingEnabled, history.count >= 5000 { history.removeFirst() }
        history.append(snap)
        let maxEntries = 5000
        if history.count > maxEntries { history.removeFirst(history.count - maxEntries) }
        if isReplayMode { replayIndex = history.count - 1 }
    }

    public func scrub(to index: Int) {
        guard !history.isEmpty else { return }
        isReplayMode = true
        let scrubTo = index > history.count - 1 ? history.count - 1 : index
        replayIndex = max(0, min(scrubTo, history.count - 1))
    }

    public func exitReplay() { isReplayMode = false }

    public func restoreFromReplay() {
        guard isReplayMode, !history.isEmpty, replayIndex < history.count else { return }
        let snap = history[replayIndex]
        history = Array(history.prefix(replayIndex + 1))

        var restored = context
        restored.cells = snap.cells
        restored.generation = snap.generation

        stopTimer()
        let actor = life.actor
        Task { @MainActor in
            await actor.send(.restore(restored))
            await actor.send(.pause)
        }
        isReplayMode = false
        replayIndex = max(0, history.count - 1)
    }

    // MARK: - Persistence (LifeContext is Codable; stored via the registered ActorSnapshotRecord model)

    private static func loadContext(modelContext: ModelContext?, key: String) -> LifeContext? {
        guard let mc = modelContext else { return nil }
        var descriptor = FetchDescriptor<ActorSnapshotRecord>(predicate: #Predicate { $0.key == key })
        descriptor.fetchLimit = 1
        guard let record = try? mc.fetch(descriptor).first else { return nil }
        return try? JSONDecoder().decode(LifeContext.self, from: Data(record.snapshotData))
    }

    public func saveSnapshot() {
        guard let mc = modelContext else { return }
        guard let data = try? JSONEncoder().encode(context) else { return }
        let key = persistenceKey
        var descriptor = FetchDescriptor<ActorSnapshotRecord>(predicate: #Predicate { $0.key == key })
        descriptor.fetchLimit = 1
        if let existing = try? mc.fetch(descriptor).first {
            existing.snapshotData = Data(Array(data))
            existing.machineId = "life"
            existing.updatedAt = .now
        } else {
            mc.insert(ActorSnapshotRecord(key: key, machineId: "life", snapshotData: Data(Array(data))))
        }
        try? mc.save()
    }

    deinit {
        // timerTask captures self weakly; it unwinds on its own once the session is gone.
    }
}
