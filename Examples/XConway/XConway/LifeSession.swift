import Foundation
import SwiftUI
import SwiftXState
import SwiftXStateSwiftUI
import SwiftData
import SwiftXStateSwiftData
import Combine

/// The bridge between SwiftUI and the SwiftXState actor.
/// Uses MachineDriver from SwiftXStateSwiftUI for observation + direct actor access for persistence.
@MainActor
@Observable
public final class LifeSession {
    public private(set) var snapshot: MachineSnapshot<LifeContext>
    public let actor: Actor<LifeContext>
    private let persistence: ActorPersistenceStore?
    // Bump this when the default grid shape changes — a persisted snapshot bakes in its own
    // width/height, so an old save would otherwise override the new LifeContext.empty() default.
    private let persistenceKey = "xconway.life.actor.v3"
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
            // Reconstruct using live constants (width/height/rules/speed don't typically change per generation;
            // the important varying parts for replay are cells + generation).
            var dc = context
            dc.cells = snap.cells
            dc.generation = snap.generation
            return dc
        }
        return context
    }

    public init(modelContext: ModelContext? = nil) {
        let machine = LifeMachineFactory.machine
        if let mc = modelContext {
            let store = ActorPersistenceStore(modelContext: mc)
            self.persistence = store
            if let restored = try? store.createActor(machine, key: persistenceKey) {
                self.actor = restored
                self.snapshot = actor.snapshot
                let c = snapshot.context
                self.history = [GridSnapshot(generation: c.generation, cells: c.cells)]
            } else {
                self.actor = createActor(machine)
                self.snapshot = actor.start(context: LifeContext.empty()).snapshot
                let c = snapshot.context
                self.history = [GridSnapshot(generation: c.generation, cells: c.cells)]
            }
        } else {
            self.persistence = nil
            self.actor = createActor(machine)
            self.snapshot = actor.start(context: LifeContext.empty()).snapshot
            let c = snapshot.context
            self.history = [GridSnapshot(generation: c.generation, cells: c.cells)]
        }

        // Keep local JSON in sync initially
        rulesJSON = snapshot.context.rules.jsonString

        // Subscribe for live updates (from driver style or manual)
        _ = actor.subscribe { [weak self] newSnap in
            Task { @MainActor in
                guard let self else { return }
                self.snapshot = newSnap
                // push rules back to text box if they changed inside machine (e.g. from template load)
                let current = newSnap.context.rules.jsonString
                if self.rulesJSON != current {
                    self.rulesJSON = current
                }
                // Intentionally do NOT save here on every snapshot — it was the main source of slowness.
            }
        }
    }

    public var context: LifeContext { snapshot.context }
    
    // MARK: - Send helpers (called from UI)

    public func send(_ event: LifeEvent) {
        actor.send(event)
        snapshot = actor.snapshot
        
        if case .step = event {
            // Record the step into the replay timeline (capped in appendToHistory), then skip the
            // rules/restore/speed/persistence handling below — none of it applies to a plain step.
            recordHistory(for: event)
            return
        }

        if case .setRulesJSON = event {
            // reflect immediately
            rulesJSON = snapshot.context.rules.jsonString
        }

        // Recording for replay / time travel
        recordHistory(for: event)

        // If we just restored, make sure we are no longer in replay mode (the sender usually clears it)
        if case .restore = event {
            isReplayMode = false
        }
        
        if case .setSpeed(let speed) = event {
            self.interval = 1/speed
        }

        // We intentionally do NOT save to SwiftData here (or in the actor subscription).
        // Auto-persisting the full actor snapshot (which includes the entire grid) after every step
        // was the primary cause of the slowness. Persistence is now explicit via the "Save Snapshot"
        // button (and a minimal save when the user changes rules via the JSON editor).
    }

    private func recordHistory(for event: LifeEvent) {
        switch event {
        case .pause:
            scrub(to: Int.max)
        case .step:
            let c = snapshot.context
            appendToHistory(GridSnapshot(generation: c.generation, cells: c.cells))

        case .clear, .randomize:
            let c = snapshot.context
            history = [GridSnapshot(generation: c.generation, cells: c.cells)]
            isReplayMode = false
            replayIndex = 0

        case .restore(let saved):
            // The caller (restoreFromReplay) already truncated; ensure head matches.
            // Note: 'saved' here is the full context from the restore event, but we store lightweight.
            let snap = GridSnapshot(generation: saved.generation, cells: saved.cells)
            if history.isEmpty || history.last?.generation != snap.generation {
                history = [snap]
            }
            replayIndex = 0

        case .loadTemplate, .toggleCell:
            // Live edits update the "present" head of the timeline when not replaying
            if !isReplayMode {
                let c = snapshot.context
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

        // Hard cap
        let maxEntries = 5000
        if history.count > maxEntries {
            let drop = history.count - maxEntries
            history.removeFirst(drop)
        }

        if isReplayMode {
            replayIndex = history.count - 1
        }
    }

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
        send(.pause)
        stopTimer()
        replayRecordingEnabled = true
        // No auto-save here anymore — user can explicitly save via the toolbar button if they want
        // the current paused state persisted to SwiftData.
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
        guard LifeRules.from(json: json) != nil else {
            return
        }
        send(.setRulesJSON(json))
            //saveIfNeeded()  // Rules change is a significant state change worth persisting
//        }
    }
    
    private var interval = 1.0/60.0
    
    public func setSpeed(_ s: Double) {
        send(.setSpeed(s))
    }

    private var timerTask: Task<Void, Never>? = nil
    
    // MARK: - Timer for autoplay (sends STEP at context.speed)

    private func startTimer() {
        timerTask = Task {
            while !Task.isCancelled {
                step()
                try? await Task.sleep(
                    for: .seconds(interval)
                )
            }
        }
    }

    private func stopTimer() {
        timerTask?.cancel()
    }

    // MARK: - Persistence (via SwiftXStateSwiftData)

    private func saveIfNeeded() {
        guard let p = persistence else { return }
        // Persist opportunistically; errors are non-fatal for a toy app
        try? p.save(actor, key: persistenceKey)
    }

    public func forceSave() {
        guard let p = persistence else { return }
        try? p.save(actor, key: persistenceKey)
    }

    /// Explicitly persists the current actor snapshot (the full grid, rules, generation, playback state, etc.)
    /// to the SwiftData store using ActorPersistenceStore. This is the "last snapshot only" write
    /// the user requested — no automatic per-step persistence happens anymore.
    public func saveSnapshot() {
        saveIfNeeded()
    }

    // Keep saveNow as an alias for backward compatibility with the button
    public func saveNow() { saveSnapshot() }

    // MARK: - Replay bar API (available when paused)

    /// Enter replay mode (or ensure it is active) and scrub the visible grid to a historical snapshot.
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

    /// Restore the live simulation state to the currently selected replay frame,
    /// truncate future history, and exit replay mode.
    public func restoreFromReplay() {
        guard isReplayMode, !history.isEmpty, replayIndex < history.count else { return }
        let snap = history[replayIndex]
        // Truncate so this becomes the new "present"
        history = Array(history.prefix(replayIndex + 1))

        // Build a full LifeContext for the restore event using the lightweight snap + current constants.
        var restored = context
        restored.cells = snap.cells
        restored.generation = snap.generation

        send(.restore(restored))
        send(.pause)  // ensure we land in paused state
        isReplayMode = false
        replayIndex = max(0, history.count - 1)
    }

    deinit {
        // Timers cleaned on main anyway
    }
}
