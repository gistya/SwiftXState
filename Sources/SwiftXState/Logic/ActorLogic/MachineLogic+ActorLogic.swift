/// `MachineLogic` is an `ActorLogic`: its reducer *is* the macrostep. For an effect-free machine
/// this conformance is total — `Actor<MachineLogic<C>>` reaches the same snapshots as `Actor`.
/// For an effectful machine the `step` still computes the right *next snapshot*; what it omits is
/// the running of side effects / `after` / `invoke`, which `Actor` does not (yet) perform.
extension MachineLogic: ActorLogic {
    public func initialState(input: SendableValue?) -> MachineSnapshot<Context> {
        initialSnapshot(input: input, context: contextOverride).snapshot
    }

    public func step(_ snapshot: MachineSnapshot<Context>, on event: any Eventable) -> MachineSnapshot<Context> {
        reduce(snapshot, on: event).snapshot
    }

    public func status(of snapshot: MachineSnapshot<Context>) -> SnapshotStatus {
        snapshot.status
    }

    public func output(of snapshot: MachineSnapshot<Context>) -> SendableValue? { snapshot.output }

    public var internalEventTypes: Set<String> { Set(machine.config.internalEvents ?? []) }

    public func childSnapshotValue(of snapshot: MachineSnapshot<Context>) -> String? { snapshot.value.description }

    public func stoppedSnapshot(_ snapshot: MachineSnapshot<Context>) -> MachineSnapshot<Context> {
        MachineSnapshot(
            machine: snapshot.machine,
            value: snapshot.value,
            context: snapshot.context,
            nodes: snapshot._nodes,
            tags: snapshot.tags,
            status: .stopped,
            historyValue: snapshot.historyValue,
            output: snapshot.output,
            error: snapshot.error,
            children: [:]
        )
    }
}
