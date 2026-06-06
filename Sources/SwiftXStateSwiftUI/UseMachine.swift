#if SWIFTXSTATE_APPLE_UI
import SwiftUI
import SwiftXState

/// Observable wrapper that drives a state machine actor in SwiftUI views.
/// Mirrors XState React's `useMachine()`.
@MainActor
@Observable
public final class MachineDriver<Context: Sendable> {
    public private(set) var snapshot: MachineSnapshot<Context>
    public let actor: Actor<Context>

    public init(_ machine: StateMachine<Context>, input: SendableValue? = nil) {
        self.actor = createActor(machine, input: input)
        self.snapshot = actor.start().snapshot
        _ = actor.subscribe { [weak self] snapshot in
            Task { @MainActor in
                self?.snapshot = snapshot
            }
        }
    }

    public func send(_ event: any Eventable) {
        actor.send(event)
        snapshot = actor.snapshot
    }
}

/// Hook-style accessor for state machine snapshots in SwiftUI.
/// Returns the driver, current snapshot, and a send function.
@MainActor
public func useMachine<Context: Sendable>(
    _ machine: StateMachine<Context>,
    input: SendableValue? = nil
) -> (snapshot: MachineSnapshot<Context>, send: (any Eventable) -> Void, actor: Actor<Context>) {
    let driver = MachineDriver(machine, input: input)
    return (
        driver.snapshot,
        { driver.send($0) },
        driver.actor
    )
}

/// Property wrapper for embedding a state machine in a SwiftUI view.
@propertyWrapper
@MainActor
public struct MachineState<Context: Sendable>: DynamicProperty {
    @State private var driver: MachineDriver<Context>

    public init(_ machine: StateMachine<Context>, input: SendableValue? = nil) {
        _driver = State(initialValue: MachineDriver(machine, input: input))
    }

    public var wrappedValue: MachineSnapshot<Context> {
        driver.snapshot
    }

    public var projectedValue: MachineDriver<Context> {
        driver
    }
}
#endif