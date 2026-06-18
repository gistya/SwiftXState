import Foundation

/// An event emitted to external listeners via `actor.on(…)`, separate from state machine events.
public struct EmittedEvent: Eventable, Sendable, Equatable {
    public let type: String
    public let properties: [String: SendableValue]

    public init(_ type: String, properties: [String: SendableValue] = [:]) {
        self.type = type
        self.properties = properties
    }

    public init(_ type: String, property key: String, value: SendableValue) {
        self.type = type
        self.properties = [key: value]
    }

    public func get<T: Sendable & Equatable>(_ key: String, as type: T.Type = T.self) -> T? {
        properties[key]?.get(type)
    }
}

/// Configuration for an `emit` action.
public struct EmitAction<Context: Sendable>: Sendable {
    public enum EventSpec: Sendable {
        case fixed(EmittedEvent)
        case expression(@Sendable (ActionArgs<Context>) -> EmittedEvent)
    }

    public let event: EventSpec

    public init(event: EventSpec) {
        self.event = event
    }
}

func resolveEmitEvent<Context: Sendable>(
    _ action: EmitAction<Context>,
    args: ActionArgs<Context>
) -> EmittedEvent {
    switch action.event {
    case let .fixed(event):
        return event
    case let .expression(expression):
        return expression(args)
    }
}

/// Emits a statically-defined event to `actor.on(…)` listeners.
public func emit<Context: Sendable>(_ event: EmittedEvent) -> ActionRef<Context> {
    .emit(EmitAction(event: .fixed(event)))
}

/// Emits an event resolved from action arguments.
public func emit<Context: Sendable>(
    _ expression: @escaping @Sendable (ActionArgs<Context>) -> EmittedEvent
) -> ActionRef<Context> {
    .emit(EmitAction(event: .expression(expression)))
}

/// Emits a type-only event.
public func emit<Context: Sendable>(_ type: String) -> ActionRef<Context> {
    emit(EmittedEvent(type))
}

// MARK: - Emit listeners

/// Registry for `actor.on(…)` and child actor emit listeners.
public final class EmitListeners: @unchecked Sendable {
    private struct Listener {
        let eventType: String
        let handler: @Sendable (EmittedEvent) -> Void
    }

    private var listeners: [Listener] = []
    private let lock = NSLock()

    public init() {}

    public func on(
        _ eventType: String,
        handler: @escaping @Sendable (EmittedEvent) -> Void
    ) -> Subscription {
        lock.lock()
        listeners.append(Listener(eventType: eventType, handler: handler))
        let index = listeners.count - 1
        lock.unlock()

        return Subscription { [weak self] in
            guard let self else { return }
            self.lock.lock()
            if index < self.listeners.count {
                self.listeners.remove(at: index)
            }
            self.lock.unlock()
        }
    }

    func notify(_ event: EmittedEvent) {
        lock.lock()
        let current = listeners
        lock.unlock()
        for listener in current where listener.eventType == "*" || listener.eventType == event.type {
            listener.handler(event)
        }
    }

    func removeAll() {
        lock.lock()
        listeners.removeAll()
        lock.unlock()
    }
}