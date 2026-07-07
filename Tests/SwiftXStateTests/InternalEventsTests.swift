import Testing
@testable import SwiftXState

/// `internalEvents` (XState v6): an event type may be **raised from within** the machine but is
/// **rejected when sent from outside** via `actor.send(...)`.
@Suite("Internal events")
struct InternalEventsTests {
    private func machine() -> ResolvedMachine<EmptyContext> {
        createMachine(MachineConfig(
            id: "sec", initial: "idle", context: EmptyContext(),
            states: [
                // GO moves to `waiting` and internally raises SECRET, which `waiting` then catches.
                "idle": StateNodeConfig(on: [
                    "GO": .single(TransitionConfig(target: "waiting", actions: [raise(Event("SECRET"))])),
                ]),
                "waiting": StateNodeConfig(on: ["SECRET": .to("caught")]),
                "caught": StateNodeConfig(),
            ],
            internalEvents: ["SECRET"]
        ))
    }

    @Test("external send of an internal event is ignored")
    func externalSendRejected() async {
        let actor = await createActor(machine()).start()
        #expect(await actor.snapshot.matches("idle"))
        await actor.send(Event("SECRET"))            // rejected — SECRET is internal-only
        #expect(await actor.snapshot.matches("idle"))
    }

    @Test("an internally raised internal event still routes")
    func internalRaiseStillWorks() async {
        let actor = await createActor(machine()).start()
        await actor.send(Event("GO"))                // GO → waiting, raises SECRET internally → caught
        await actor.waitForSnapshot { $0.matches("caught") }
        #expect(await actor.snapshot.matches("caught"))
    }
}
