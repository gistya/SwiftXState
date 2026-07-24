import SwiftXState

// Transport-agnostic bridge: run a SwiftXState machine behind a Codable boundary.
// Hold a `MachineHost` inside any isolation domain (a distributed actor, an XPC service,
// a server) and drive it with plain event names; hand back a Codable `MachineReport`.
// No WebWorkerKit here — this is just SwiftXState + Codable, so it composes with any
// `DistributedActorSystem` (Web Workers, XPC, gRPC…).

/// A Codable snapshot of a machine's observable state — the value carried across the wire.
public struct MachineReport<Context: Codable & Sendable>: Codable, Sendable {
    /// The active state value, e.g. `"counting"` or `"red"`.
    public let state: String
    /// The current context.
    public let context: Context
    /// Of the machine's declared event vocabulary, the events a caller may send *right now*
    /// (guards satisfied, a transition exists). Lets a remote UI enable/disable controls
    /// without re-encoding the machine's guards — the worker is the single source of truth.
    public let enabled: [String]
    /// Whether the machine reached a top-level final state.
    public let done: Bool

    public init(state: String, context: Context, enabled: [String], done: Bool) {
        self.state = state
        self.context = context
        self.enabled = enabled
        self.done = done
    }
}

/// Owns a machine + its live snapshot and steps it synchronously via the pure reducer.
/// Not `Sendable` — hold it inside a single isolation domain (e.g. a distributed actor),
/// which serializes access.
public final class MachineHost<Context: Sendable & Equatable & Codable> {
    private let logic: MachineLogic<Context>
    private var snapshot: MachineSnapshot<Context>
    /// The machine's full event vocabulary — the candidates `report()` tests with `can`.
    private let vocabulary: [String]

    /// Host any resolved machine — authored with `createMachine(MachineConfig(...))` or
    /// with the Plan D DSL (`StateMachine.resolvedMachine(id:)`); both yield a
    /// `ResolvedMachine`, so the DSL composes with distribution for free.
    ///
    /// - Parameter events: the machine's event vocabulary. `report()` returns the subset of
    ///   these that are currently sendable, so a remote UI can render guard-aware controls.
    public init(_ machine: ResolvedMachine<Context>, events: [String] = []) {
        self.logic = MachineLogic(machine: machine)
        self.snapshot = logic.initialState(input: nil)
        self.vocabulary = events
    }

    /// Apply one event (by type) and return the new report.
    @discardableResult
    public func send(_ eventType: String) -> MachineReport<Context> {
        snapshot = logic.step(snapshot, on: Event(eventType))
        return report()
    }

    /// The current report without advancing.
    public func report() -> MachineReport<Context> {
        MachineReport(
            state: snapshot.value.description,
            context: snapshot.context,
            enabled: vocabulary.filter { snapshot.can(Event($0)) },
            done: snapshot.status == .done
        )
    }
}
