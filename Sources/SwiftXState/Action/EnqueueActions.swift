import Foundation

/// Builder passed to `enqueueActions` for conditional action batches.
public final class EnqueueActionsBuilder<Context: Sendable>: @unchecked Sendable {
    private(set) var actions: [ActionRef<Context>] = []
    public let context: Context
    public let event: any Eventable
    public let stateValue: StateValue
    private let implementations: MachineImplementations<Context>

    init(
        context: Context,
        event: any Eventable,
        stateValue: StateValue,
        implementations: MachineImplementations<Context>
    ) {
        self.context = context
        self.event = event
        self.stateValue = stateValue
        self.implementations = implementations
    }

    public func enqueue(_ action: ActionRef<Context>) {
        actions.append(action)
    }

    /// Enqueue an event to be sent to the child actor with the given id.
    public func sendTo(_ childId: String, _ event: Event) {
        enqueue(.sendTo(SendToAction(target: .fixed(childId), event: .fixed(event))))
    }

    public func sendTo(
        _ childId: String,
        _ expression: @escaping @Sendable (ActionArgs<Context>) -> Event
    ) {
        enqueue(.sendTo(SendToAction(target: .fixed(childId), event: .expression(expression))))
    }

    public func sendTo(
        _ target: @escaping @Sendable (ActionArgs<Context>) -> String,
        _ event: Event
    ) {
        enqueue(.sendTo(SendToAction(target: .expression(target), event: .fixed(event))))
    }

    public func check(_ guardRef: GuardRef<Context>) -> Bool {
        evaluateGuard(
            guardRef,
            args: ActionArgs(context: context, event: event),
            implementations: implementations,
            stateValue: stateValue
        )
    }
}

func flattenActions<Context: Sendable>(
    _ actions: [ExecutableAction<Context>],
    context: Context,
    event: any Eventable,
    stateValue: StateValue,
    implementations: MachineImplementations<Context>
) -> [ExecutableAction<Context>] {
    var flattened: [ExecutableAction<Context>] = []

    for action in actions {
        guard case let .enqueueActions(body) = action.ref else {
            flattened.append(action)
            continue
        }

        flattened.append(action)

        let builder = EnqueueActionsBuilder(
            context: context,
            event: event,
            stateValue: stateValue,
            implementations: implementations
        )
        body(builder)
        flattened.append(
            contentsOf: flattenActions(
                builder.actions.map { ExecutableAction(ref: $0) },
                context: context,
                event: event,
                stateValue: stateValue,
                implementations: implementations
            )
        )
    }

    return flattened
}

/// Enqueues actions conditionally, mirroring XState's `enqueueActions`.
public func enqueueActions<Context: Sendable>(
    _ body: @escaping @Sendable (EnqueueActionsBuilder<Context>) -> Void
) -> ActionRef<Context> {
    .enqueueActions(body)
}