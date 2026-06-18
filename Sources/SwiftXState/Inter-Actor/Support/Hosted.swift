/// Interactor-isolated box over a generic `Reactor<Context>`. Only ever touched on the owning
/// Interactor's executor; the inspection-forwarding closure it installs captures only `Sendable`
/// values (the bus, the clock, ids), never the box.
protocol AnyHosted: AnyObject, Sendable {
    var reactorID: String { get }
    func post(_ event: any Eventable)
    func stop()
    func restart()
    func currentStateValue() -> String
    /// A stream that yields whenever the *current* reactor instance enters `state`. Only the yields
    /// (`Void`) cross threads; the box itself is never touched off the Interactor's executor.
    func failureSignals(matching state: String) -> AsyncStream<Void>
}

final class Hosted<Context: Sendable>: AnyHosted, @unchecked Sendable {
    let reactorID: String
    let machine: StateMachine<Context>
    let inspect: @Sendable (InspectionEvent) -> Void
    private(set) var reactor: Reactor<Context>

    init(
        reactorID: String,
        machine: StateMachine<Context>,
        reactor: Reactor<Context>,
        inspect: @escaping @Sendable (InspectionEvent) -> Void
    ) {
        self.reactorID = reactorID
        self.machine = machine
        self.reactor = reactor
        self.inspect = inspect
    }

    func post(_ event: any Eventable) { reactor.post(event) }
    func stop() { reactor.stop() }

    func restart() {
        reactor.stop()
        reactor = createReactor(machine, id: reactorID, options: ReactorOptions(inspect: inspect)).start()
    }

    func currentStateValue() -> String { reactor.snapshot.value.description }
    func snapshot() -> MachineSnapshot<Context> { reactor.snapshot }

    func failureSignals(matching state: String) -> AsyncStream<Void> {
        AsyncStream { continuation in
            let subscription = reactor.subscribe { snapshot in
                if snapshot.matches(state) { continuation.yield(()) }
            }
            continuation.onTermination = { _ in subscription.cancel() }
        }
    }
}
