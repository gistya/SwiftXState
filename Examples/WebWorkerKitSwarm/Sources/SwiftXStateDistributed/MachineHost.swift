import SwiftXState

// Transport-agnostic bridge: run a SwiftXState machine behind a Codable boundary.
// Hold a `MachineHost` inside any isolation domain (a distributed actor, an XPC service,
// a server) and drive it with plain event names; hand back a Codable `MachineReport`.
// No WebWorkerKit here — this is just SwiftXState + Codable, so it composes with any
// `DistributedActorSystem` (Web Workers, XPC, gRPC…).

/// A Codable snapshot of a machine's observable state — the value carried across the wire.
public struct MachineReport<Context: Codable & Sendable>: Codable, Sendable {
    /// The active state value, e.g. `"counting"` or `"red.walk"`.
    public let state: String
    /// The current context.
    public let context: Context
    /// Whether the machine reached a top-level final state.
    public let done: Bool

    public init(state: String, context: Context, done: Bool) {
        self.state = state
        self.context = context
        self.done = done
    }
}

/// Owns a machine + its live snapshot and steps it synchronously via the pure reducer.
/// Not `Sendable` — hold it inside a single isolation domain (e.g. a distributed actor),
/// which serializes access.
public final class MachineHost<Context: Sendable & Equatable & Codable> {
    private let logic: MachineLogic<Context>
    private var snapshot: MachineSnapshot<Context>

    /// Host any resolved machine — authored with `createMachine(MachineConfig(...))` or
    /// with the Plan D DSL (`StateMachine.resolvedMachine(id:)`); both yield a
    /// `ResolvedMachine`, so the DSL composes with distribution for free.
    public init(_ machine: ResolvedMachine<Context>) {
        self.logic = MachineLogic(machine: machine)
        self.snapshot = logic.initialState(input: nil)
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
            done: snapshot.status == .done
        )
    }
}
