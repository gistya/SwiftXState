#if SWIFTXSTATE_APPLE_UI
import SwiftUI
import SwiftXState

private final class WeakMachineDriverBox<Object: AnyObject>: @unchecked Sendable {
    weak var object: Object?

    init(_ object: Object) {
        self.object = object
    }
}

/// Observable wrapper that drives a state machine actor in SwiftUI views.
/// Mirrors XState React's `useMachine()`.
@MainActor
@Observable
public final class MachineDriver<Context: Sendable> {
    public private(set) var snapshot: MachineSnapshot<Context>
    public let actor: Actor<MachineLogic<Context>>

    @ObservationIgnored private var subscription: Subscription?

    public init(_ machine: ResolvedMachine<Context>, input: SendableValue? = nil) {
        self.actor = createActor(machine, input: input)
        self.snapshot = initialTransition(machine, input: input).snapshot

        let box = WeakMachineDriverBox(self)
        Task { [box, actor, input] in
            await actor.start(input: input)
            let subscription = await actor.subscribe { snapshot in
                Task { @MainActor [box] in
                    box.object?.snapshot = snapshot
                }
            }
            await MainActor.run { [box] in
                box.object?.subscription = subscription
            }
        }
    }

    deinit {
        subscription?.cancel()
    }

    public func send(_ event: any Eventable) {
        Task { [weak self, actor] in
            await actor.send(event)
            let snapshot = await actor.snapshot
            await MainActor.run {
                self?.snapshot = snapshot
            }
        }
    }
}

/// Hook-style accessor for state machine snapshots in SwiftUI.
/// Returns the driver, current snapshot, and a send function.
@MainActor
public func useMachine<Context: Sendable>(
    _ machine: ResolvedMachine<Context>,
    input: SendableValue? = nil
) -> (snapshot: MachineSnapshot<Context>, send: (any Eventable) -> Void, actor: Actor<MachineLogic<Context>>) {
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

    public init(_ machine: ResolvedMachine<Context>, input: SendableValue? = nil) {
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
