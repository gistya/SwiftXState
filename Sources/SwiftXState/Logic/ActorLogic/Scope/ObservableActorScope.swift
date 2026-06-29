/// Scope passed to observable actor logic (`fromObservable`).
public struct ObservableActorScope: Sendable {
    public let input: SendableValue?
    public let system: ActorSystem
    public let emit: @Sendable (EmittedEvent) -> Void

    public init(
        input: SendableValue?,
        system: ActorSystem,
        emit: @escaping @Sendable (EmittedEvent) -> Void
    ) {
        self.input = input
        self.system = system
        self.emit = emit
    }
}
