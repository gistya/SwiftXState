import Foundation

/// The inspection side of `MachineLogic`'s `ActorLogic` conformance: builds the machine-specific
/// `@xstate.*` events from `MachineSnapshot`. `LogicActor` owns the *plumbing* (the `inspectable`
/// gate, the `@autoclosure`-guarded emit, and the lifecycle timing); the logic supplies the payloads
/// here, since only it knows the `Context`/`MachineSnapshot`.
extension MachineLogic {
    var providesInspection: Bool { true }

    func inspectionMachineId() -> String? { machine.id }

    func inspectionRegistrationEvent(
        _ snapshot: MachineSnapshot<Context>, actor: InspectionActorRef, rootId: String,
        parentSessionId: String?, includeDefinition: Bool
    ) -> InspectionEvent? {
        .actor(
            rootId: rootId,
            actor: actor,
            parentSessionId: parentSessionId,
            registrationSnapshot: .from(snapshot, actor: actor),
            definitionJSON: includeDefinition ? (try? machine.definitionJSON()) : nil
        )
    }

    func inspectionTransitionEvent(
        _ snapshot: MachineSnapshot<Context>, event: any Eventable, actor: InspectionActorRef, rootId: String
    ) -> InspectionEvent? {
        .transition(rootId: rootId, actor: actor, triggeringEvent: event, machineSnapshot: snapshot)
    }

    func inspectionSnapshotEvent(
        _ snapshot: MachineSnapshot<Context>, event: any Eventable, actor: InspectionActorRef, rootId: String
    ) -> InspectionEvent? {
        .snapshot(rootId: rootId, actor: actor, triggeringEvent: event, machineSnapshot: snapshot)
    }

    func startupActionTypes(input: SendableValue?) -> [String] {
        // Re-derive the initial actions (pure) and keep the inspectable ones — `LogicActor` emits
        // these as `.action` events after the `.actor` registration, matching Actor's order.
        let (_, actions) = initialSnapshot(input: input, context: nil)
        return actions.compactMap { action in
            if case let .spawn(spawn) = action.ref, !spawn.inspectable { return nil }
            return action.type
        }
    }
}
