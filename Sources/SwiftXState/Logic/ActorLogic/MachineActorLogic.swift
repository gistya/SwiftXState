/// A logic that wraps a `ResolvedMachine` — the capability behind the machine-shaped `Actor`
/// conveniences (`Actor(_ machine:)`, `start(context:)`, `getSnapshot()`). Only
/// `MachineLogic` conforms; it lets those conveniences live on `Actor where L: MachineActorLogic`
/// without `Actor` itself knowing about state machines.
public protocol MachineActorLogic: ActorLogic where Snapshot == MachineSnapshot<MachineContext> {
    associatedtype MachineContext: Sendable
    var machine: ResolvedMachine<MachineContext> { get }
    init(machine: ResolvedMachine<MachineContext>, contextOverride: MachineContext?)
}

extension MachineLogic: MachineActorLogic {
    public typealias MachineContext = Context
}
