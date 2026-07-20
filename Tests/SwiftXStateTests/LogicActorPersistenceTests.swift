import Testing
import Foundation
@testable import SwiftXState
import SwiftXStateCodable

private struct PCtx: Codable, Sendable, Equatable, ContextPersistable { var count: Int }

@Suite("Actor persistence")
struct LogicActorPersistenceTests {

    private func counterMachine() -> ResolvedMachine<PCtx> {
        createMachine(MachineConfig(
            id: "counter", initial: "active", context: PCtx(count: 0),
            states: [
                "active": StateNodeConfig(on: [
                    "INC": .single(TransitionConfig(actions: [assign { ctx, _ in ctx.count += 1 }])),
                ]),
            ]
        ))
    }

    @Test("saved snapshot matches Actor")
    func saveParity() async throws {
        let machine = counterMachine()
        let old = await createActor(machine).start()
        let new = await Actor(MachineLogic(machine: machine)).start()
        await old.send(Event("INC")); await old.send(Event("INC"))
        await new.send(Event("INC")); await new.send(Event("INC"))

        let oldP = try await old.getPersistedSnapshot()
        let newP = try await new.getPersistedSnapshot()
        #expect(oldP == newP)
        #expect(newP.value == .atomic("active"))
    }

    @Test("saved snapshot round-trips through Actor.start(from:)")
    func saveRoundTripsViaActor() async throws {
        // Until Actor.start(from:) lands, prove the bytes Actor produces are restorable
        // by the existing Actor restore path — i.e. they're genuinely compatible, not just equal.
        let machine = counterMachine()
        let new = await Actor(MachineLogic(machine: machine)).start()
        await new.send(Event("INC")); await new.send(Event("INC")); await new.send(Event("INC"))
        let persisted = try await new.getPersistedSnapshot()

        let restored = await createActor(machine).start(from: persisted)
        #expect(await restored.snapshot.context.count == 3)
        #expect(await restored.snapshot.matches("active"))
    }

    @Test("Actor.start(from:) restores state + context, then keeps running")
    func restoreParity() async throws {
        let machine = counterMachine()
        // Produce a persisted snapshot via Actor, then restore it into a Actor.
        let source = await createActor(machine).start()
        await source.send(Event("INC")); await source.send(Event("INC")); await source.send(Event("INC"))
        let persisted = try await source.getPersistedSnapshot()

        let restored = await Actor(MachineLogic(machine: machine)).start(from: persisted)
        #expect(await restored.snapshot.context.count == 3)
        #expect(await restored.snapshot.matches("active"))
        // Restored actor is live.
        await restored.send(Event("INC"))
        #expect(await restored.snapshot.context.count == 4)
    }

    @Test("round-trip: Actor save → Actor restore")
    func roundTrip() async throws {
        let machine = counterMachine()
        let a = await Actor(MachineLogic(machine: machine)).start()
        await a.send(Event("INC")); await a.send(Event("INC"))
        let persisted = try await a.getPersistedSnapshot()

        let b = await Actor(MachineLogic(machine: machine)).start(from: persisted)
        #expect(await b.snapshot.context.count == 2)
        #expect(await b.snapshot.matches("active"))
    }

    @Test("restore re-spawns invoke children, like Actor")
    func restoreChildren() async throws {
        let child = createMachine(MachineConfig(initial: "run", context: PCtx(count: 0),
            states: ["run": StateNodeConfig()]))
        let parent = createMachine(MachineConfig(
            id: "parent", initial: "active", context: PCtx(count: 0),
            states: [
                "active": StateNodeConfig(invoke: [
                    InvokeConfig(id: "kid", src: .machine(MachineActorLogicBox(child) { _ in PCtx(count: 0) })),
                ]),
            ]
        ))
        let source = await createActor(parent).start()
        let persisted = try await source.getPersistedSnapshot()

        let oldRestored = await createActor(parent).start(from: persisted)
        let newRestored = await Actor(MachineLogic(machine: parent)).start(from: persisted)
        #expect(await oldRestored.snapshot.children.keys.sorted() == newRestored.snapshot.children.keys.sorted())
        #expect(await newRestored.snapshot.children.keys.sorted() == ["kid"])
    }
}
