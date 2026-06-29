/// Scope passed to transition-based actor logic (`fromTransition`).
public struct TransitionActorScope {
    public let input: SendableValue?
    public let system: ActorSystem
    public let sendToParent: (any Eventable) -> Void
    public let emit: (EmittedEvent) -> Void

    public init(
        input: SendableValue?,
        system: ActorSystem,
        sendToParent: @escaping (any Eventable) -> Void,
        emit: @escaping (EmittedEvent) -> Void
    ) {
        self.input = input
        self.system = system
        self.sendToParent = sendToParent
        self.emit = emit
    }
}
