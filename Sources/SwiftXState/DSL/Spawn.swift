
// MARK: - enq.spawn / enq.stopChild — dynamic child actors from a handler

public extension Enqueue {
    /// Spawn a child **state machine** as a deferred effect — XState v6's `enq.spawn`. The child runs
    /// under this actor; `context` seeds its initial context (per spawned instance, so 96 board
    /// squares each get their own), and `id` names it for `sendTo` / `stopChild` / inspection.
    ///
    /// Works from any handler, including `onEntry` — spawn a fleet of children when a state is entered:
    ///
    /// ```swift
    /// XState(.playing) {}.initial().onEntry { args, enq in
    ///     for square in args.context.board {
    ///         enq.spawn(SquareMachine(), id: square.id, context: SquareContext(square), inspectable: false)
    ///     }
    ///     return args.context
    /// }
    /// ```
    func spawn<Child: StateMachine>(
        _ machine: Child,
        id: String,
        context: Child.Context? = nil,
        systemId: String? = nil,
        syncSnapshot: Bool = false,
        inspectable: Bool = true
    ) {
        let resolved = machine.resolvedMachine(id: id)
        let source: ActorSource = context.map { fromMachine(resolved, context: $0) } ?? fromMachine(resolved)
        collected.append(spawnChild(source, id: id, systemId: systemId, syncSnapshot: syncSnapshot, inspectable: inspectable))
    }

    /// Spawn a child from an already-built `ActorSource` (the escape hatch — tasks, callbacks, stores).
    func spawn(
        _ source: ActorSource,
        id: String,
        systemId: String? = nil,
        syncSnapshot: Bool = false,
        inspectable: Bool = true
    ) {
        collected.append(spawnChild(source, id: id, systemId: systemId, syncSnapshot: syncSnapshot, inspectable: inspectable))
    }

    /// Stop a spawned/invoked child by id — XState v6's `enq.stopChild`.
    func stopChild(_ id: String) {
        collected.append(SwiftXState.stopChild(id))
    }
}
