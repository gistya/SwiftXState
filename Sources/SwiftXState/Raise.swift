import Foundation

/// A delayed event produced by a `raise` action with a `delay`.
public struct DelayedRaise: Sendable, Equatable {
    public let event: Event
    public let delayMs: Int
    public let id: String?

    public init(event: Event, delayMs: Int, id: String? = nil) {
        self.event = event
        self.delayMs = delayMs
        self.id = id
    }
}

/// Configuration for a `raise` action.
public struct RaiseAction<Context: Sendable>: Sendable {
    public enum EventSource: Sendable {
        case fixed(Event)
        case expression(@Sendable (ActionArgs<Context>) -> Event)
    }

    public let event: EventSource
    public let delayMs: Int?
    public let delayKey: String?
    public let id: String?

    public init(
        event: EventSource,
        delayMs: Int? = nil,
        delayKey: String? = nil,
        id: String? = nil
    ) {
        self.event = event
        self.delayMs = delayMs
        self.delayKey = delayKey
        self.id = id
    }
}

struct ResolvedRaise: Sendable, Equatable {
    let event: Event
    let delayMs: Int?
    let id: String?
}

func resolveRaiseEvent<Context: Sendable>(
    _ raise: RaiseAction<Context>,
    args: ActionArgs<Context>
) -> Event {
    switch raise.event {
    case let .fixed(event):
        return event
    case let .expression(expression):
        return expression(args)
    }
}

func resolveRaiseDelay<Context: Sendable>(
    _ raise: RaiseAction<Context>,
    args: ActionArgs<Context>,
    delays: [String: @Sendable (ActionArgs<Context>) -> Int]
) -> Int? {
    if let delayMs = raise.delayMs {
        return delayMs
    }
    if let delayKey = raise.delayKey {
        return delays[delayKey]?(args)
    }
    return nil
}

func resolveRaise<Context: Sendable>(
    _ raise: RaiseAction<Context>,
    args: ActionArgs<Context>,
    delays: [String: @Sendable (ActionArgs<Context>) -> Int]
) -> ResolvedRaise {
    ResolvedRaise(
        event: resolveRaiseEvent(raise, args: args),
        delayMs: resolveRaiseDelay(raise, args: args, delays: delays),
        id: raise.id
    )
}

/// Resolves assign and raise actions, enqueueing immediate raises on the internal queue.
func resolveBuiltInActions<Context: Sendable>(
    _ actions: [ExecutableAction<Context>],
    context: inout Context,
    event: any Eventable,
    implementations: MachineImplementations<Context>,
    internalQueue: inout [any Eventable],
    delayedRaises: inout [DelayedRaise]
) -> [ExecutableAction<Context>] {
    var resolvedActions = actions

    for index in resolvedActions.indices {
        let args = ActionArgs(context: context, event: event)
        executeAssignOnly(
            resolvedActions[index],
            context: &context,
            args: args,
            implementations: implementations
        )

        guard case let .raise(raiseAction) = resolvedActions[index].ref else { continue }

        let resolved = resolveRaise(
            raiseAction,
            args: args,
            delays: implementations.delays
        )

        if let delayMs = resolved.delayMs {
            resolvedActions[index].delayedEvent = resolved.event
            resolvedActions[index].delayMs = delayMs
            resolvedActions[index].timerId = resolved.id ?? resolved.event.type
            delayedRaises.append(
                DelayedRaise(event: resolved.event, delayMs: delayMs, id: resolved.id)
            )
        } else {
            internalQueue.append(resolved.event)
        }
    }

    return resolvedActions
}

/// Resolves only `raise` actions from a pending action list (assigns already applied).
func resolveRaiseActionsOnly<Context: Sendable>(
    _ actions: [ExecutableAction<Context>],
    context: Context,
    event: any Eventable,
    implementations: MachineImplementations<Context>,
    internalQueue: inout [any Eventable],
    delayedRaises: inout [DelayedRaise]
) -> [ExecutableAction<Context>] {
    var resolvedActions = actions

    for index in resolvedActions.indices {
        guard case let .raise(raiseAction) = resolvedActions[index].ref else { continue }

        let args = ActionArgs(context: context, event: event)
        let resolved = resolveRaise(
            raiseAction,
            args: args,
            delays: implementations.delays
        )

        if let delayMs = resolved.delayMs {
            resolvedActions[index].delayedEvent = resolved.event
            resolvedActions[index].delayMs = delayMs
            resolvedActions[index].timerId = resolved.id ?? resolved.event.type
            delayedRaises.append(
                DelayedRaise(event: resolved.event, delayMs: delayMs, id: resolved.id)
            )
        } else {
            internalQueue.append(resolved.event)
        }
    }

    return resolvedActions
}

/// Raises an event on the internal queue, consumed in the current macrostep.
public func raise<Context: Sendable>(_ event: Event) -> ActionRef<Context> {
    .raise(RaiseAction(event: .fixed(event)))
}

/// Raises an event resolved from action arguments.
public func raise<Context: Sendable>(
    _ expression: @escaping @Sendable (ActionArgs<Context>) -> Event
) -> ActionRef<Context> {
    .raise(RaiseAction(event: .expression(expression)))
}

/// Raises an event after a delay in milliseconds.
public func raise<Context: Sendable>(
    _ event: Event,
    delay milliseconds: Int,
    id: String? = nil
) -> ActionRef<Context> {
    .raise(RaiseAction(event: .fixed(event), delayMs: milliseconds, id: id))
}

/// Raises an event after a named delay from `setup(delays:)`.
public func raise<Context: Sendable>(
    _ event: Event,
    delay delayKey: String,
    id: String? = nil
) -> ActionRef<Context> {
    .raise(RaiseAction(event: .fixed(event), delayKey: delayKey, id: id))
}