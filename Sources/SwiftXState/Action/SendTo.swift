import Foundation

/// Configuration for a `sendTo` action.
public struct SendToAction<Context: Sendable>: Sendable {
    public enum EventSource: Sendable {
        case fixed(Event)
        case expression(@Sendable (ActionArgs<Context>) -> Event)
    }

    public let target: ChildTarget<Context>
    public let event: EventSource
    public let delayMs: Int?
    public let delayKey: String?
    public let id: String?

    public init(
        target: ChildTarget<Context>,
        event: EventSource,
        delayMs: Int? = nil,
        delayKey: String? = nil,
        id: String? = nil
    ) {
        self.target = target
        self.event = event
        self.delayMs = delayMs
        self.delayKey = delayKey
        self.id = id
    }
}

struct ResolvedSendTo: Sendable, Equatable {
    let childId: String
    let event: Event
    let delayMs: Int?
    let id: String?
}

func resolveSendToEvent<Context: Sendable>(
    _ sendTo: SendToAction<Context>,
    args: ActionArgs<Context>
) -> Event {
    switch sendTo.event {
    case let .fixed(event):
        return event
    case let .expression(expression):
        return expression(args)
    }
}

func resolveSendToDelay<Context: Sendable>(
    _ sendTo: SendToAction<Context>,
    args: ActionArgs<Context>,
    delays: [String: @Sendable (ActionArgs<Context>) -> Int]
) -> Int? {
    if let delayMs = sendTo.delayMs {
        return delayMs
    }
    if let delayKey = sendTo.delayKey {
        return delays[delayKey]?(args)
    }
    return nil
}

func resolveSendTo<Context: Sendable>(
    _ sendTo: SendToAction<Context>,
    args: ActionArgs<Context>,
    delays: [String: @Sendable (ActionArgs<Context>) -> Int]
) -> ResolvedSendTo {
    ResolvedSendTo(
        childId: resolveChildTarget(sendTo.target, args: args),
        event: resolveSendToEvent(sendTo, args: args),
        delayMs: resolveSendToDelay(sendTo, args: args, delays: delays),
        id: sendTo.id
    )
}

/// Sends an event to a child actor, mirroring XState's `sendTo`.
public func sendTo<Context: Sendable>(_ childId: String, _ event: Event) -> ActionRef<Context> {
    .sendTo(SendToAction(target: .fixed(childId), event: .fixed(event)))
}

/// Sends a dynamically resolved event to a child actor.
public func sendTo<Context: Sendable>(
    _ childId: String,
    _ expression: @escaping @Sendable (ActionArgs<Context>) -> Event
) -> ActionRef<Context> {
    .sendTo(SendToAction(target: .fixed(childId), event: .expression(expression)))
}

/// Sends an event to a child whose id is resolved at runtime.
public func sendTo<Context: Sendable>(
    _ target: @escaping @Sendable (ActionArgs<Context>) -> String,
    _ event: Event
) -> ActionRef<Context> {
    .sendTo(SendToAction(target: .expression(target), event: .fixed(event)))
}

/// Sends a dynamically resolved event to a child whose id is resolved at runtime.
public func sendTo<Context: Sendable>(
    _ target: @escaping @Sendable (ActionArgs<Context>) -> String,
    _ expression: @escaping @Sendable (ActionArgs<Context>) -> Event
) -> ActionRef<Context> {
    .sendTo(SendToAction(target: .expression(target), event: .expression(expression)))
}

/// Sends an event to a child actor after a delay in milliseconds.
public func sendTo<Context: Sendable>(
    _ childId: String,
    _ event: Event,
    delay milliseconds: Int,
    id: String? = nil
) -> ActionRef<Context> {
    .sendTo(SendToAction(
        target: .fixed(childId),
        event: .fixed(event),
        delayMs: milliseconds,
        id: id
    ))
}

/// Sends an event to a child actor after a named delay from `setup(delays:)`.
public func sendTo<Context: Sendable>(
    _ childId: String,
    _ event: Event,
    delay delayKey: String,
    id: String? = nil
) -> ActionRef<Context> {
    .sendTo(SendToAction(
        target: .fixed(childId),
        event: .fixed(event),
        delayKey: delayKey,
        id: id
    ))
}