/// Scope passed to callback-based actor logic (`fromCallback`).
public struct CallbackActorScope: Sendable {
    public let input: SendableValue?
    public let sendToParent: @Sendable (any Eventable) -> Void
    public let receive: @Sendable (@escaping @Sendable (any Eventable) -> Void) -> Void
    public let emit: @Sendable (EmittedEvent) -> Void
    public let system: ActorSystem

    public init(
        input: SendableValue?,
        sendToParent: @escaping @Sendable (any Eventable) -> Void,
        receive: @escaping @Sendable (@escaping @Sendable (any Eventable) -> Void) -> Void,
        emit: @escaping @Sendable (EmittedEvent) -> Void,
        system: ActorSystem
    ) {
        self.input = input
        self.sendToParent = sendToParent
        self.receive = receive
        self.emit = emit
        self.system = system
    }

    /// Sends an event to the parent actor. Matches XState's `sendBack(event)`.
    ///
    /// Accepts any `Eventable`, including `Event("TYPE")` and string literals (`"TYPE"`).
    public var sendBack: @Sendable (any Eventable) -> Void {
        sendToParent
    }
}
