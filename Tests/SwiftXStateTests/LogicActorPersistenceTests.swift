import Testing
import Foundation
@testable import SwiftXState

private struct PCtx: Codable, Sendable, Equatable { var count: Int }

@Suite("LogicActor persistence")
struct LogicActorPersistenceTests {

    private func counterMachine() -> StateMachine<PCtx> {
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
        let new = await LogicActor(MachineLogic(machine: machine)).start()
        await old.send(Event("INC")); await old.send(Event("INC"))
        await new.send(Event("INC")); await new.send(Event("INC"))

        let oldP = try await old.getPersistedSnapshot()
        let newP = try await new.getPersistedSnapshot()
        #expect(oldP == newP)
        #expect(newP.value == .atomic("active"))
    }

    @Test("saved snapshot round-trips through Actor.start(from:)")
    func saveRoundTripsViaActor() async throws {
        // Until LogicActor.start(from:) lands, prove the bytes LogicActor produces are restorable
        // by the existing Actor restore path — i.e. they're genuinely compatible, not just equal.
        let machine = counterMachine()
        let new = await LogicActor(MachineLogic(machine: machine)).start()
        await new.send(Event("INC")); await new.send(Event("INC")); await new.send(Event("INC"))
        let persisted = try await new.getPersistedSnapshot()

        let restored = await createActor(machine).start(from: persisted)
        #expect(await restored.snapshot.context.count == 3)
        #expect(await restored.snapshot.matches("active"))
    }
}
