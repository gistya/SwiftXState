/// Interactor-isolated box over a generic `Actor<Context>`. Only ever touched on the owning
/// Interactor's executor; the inspection-forwarding closure it installs captures only `Sendable`
/// values (the bus, the clock, ids), never the box.
protocol AnyHosted: AnyObject, Sendable {
    var actorID: String { get }
    func post(_ event: any Eventable)
    func stop()
    func restart()
    func currentStateValue() -> String
    /// A stream that yields whenever the *current* actor instance enters `state`. Only the yields
    /// (`Void`) cross threads; the box itself is never touched off the Interactor's executor.
    func failureSignals(matching state: String) -> AsyncStream<Void>
}

final class Hosted<Context: Sendable>: AnyHosted, @unchecked Sendable {
    let actorID: String
    let machine: StateMachine<Context>
    let inspect: @Sendable (InspectionEvent) -> Void
    private(set) var actor: Reactor<Context>

    init(
        actorID: String,
        machine: StateMachine<Context>,
        actor: Reactor<Context>,
        inspect: @escaping @Sendable (InspectionEvent) -> Void
    ) {
        self.actorID = actorID
        self.machine = machine
        self.actor = actor
        self.inspect = inspect
    }

    func post(_ event: any Eventable) { actor.post(event) }
    func stop() { actor.stop() }

    func restart() {
        actor.stop()
        actor = createReactor(machine, id: actorID, options: ReactorOptions(inspect: inspect)).start()
    }

    func currentStateValue() -> String { actor.snapshot.value.description }
    func snapshot() -> MachineSnapshot<Context> { actor.snapshot }

    func failureSignals(matching state: String) -> AsyncStream<Void> {
        AsyncStream { continuation in
            let subscription = actor.subscribe { snapshot in
                if snapshot.matches(state) { continuation.yield(()) }
            }
            continuation.onTermination = { _ in subscription.cancel() }
        }
    }
}
