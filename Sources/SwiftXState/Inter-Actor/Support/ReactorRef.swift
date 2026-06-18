/// A `Sendable`, typed handle to a reactor hosted by an ``Interactor`` — the inter-actor *address*.
/// Sends are asynchronous and routed through the owning Interactor, so a ref works the same
/// whether the target lives in the same Interactor or a peer (location transparency). The event
/// argument is a concrete ``StateEvent`` value, so messaging stays string-free and compiler-checked.
public struct ReactorRef<Context: Sendable>: Sendable {
    public let id: String
    public let interactorID: String
    let interactor: Interactor

    public var address: ReactorAddress { ReactorAddress(interactorID: interactorID, reactorID: id) }

    /// Deliver a typed event. Non-blocking and FIFO-ordered at the target's mailbox.
    public func send(_ event: some Eventable) async {
        await interactor.route(event, to: id, from: nil)
    }

    /// Deliver a typed event, attributing it to a sending reactor `from` — typically another
    /// Interactor's reactor. The attribution surfaces as a cross-domain edge in the unified graph.
    public func send(_ event: some Eventable, from source: ReactorAddress) async {
        await interactor.route(event, to: id, from: source)
    }

    /// Read the current typed snapshot (state value, context, tags). `nil` if the reactor is gone.
    public func snapshot() async -> MachineSnapshot<Context>? {
        await interactor.snapshot(of: id, as: Context.self)
    }

    /// Supervised restart: tear the reactor down and recreate it from its initial state.
    public func restart() async {
        await interactor.restart(reactorID: id)
    }
}
