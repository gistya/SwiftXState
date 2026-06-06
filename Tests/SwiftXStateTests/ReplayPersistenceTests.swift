import Testing
@testable import SwiftXState

private struct ReplayPersistContext: Sendable, Equatable, Codable {
    var count: Int
}

@Suite("Replay session persistence")
struct ReplayPersistenceTests {
    private var counterMachine: StateMachine<ReplayPersistContext> {
        createMachine(MachineConfig(
            id: "counter",
            initial: "idle",
            context: ReplayPersistContext(count: 0),
            states: [
                "idle": StateNodeConfig(on: [
                    "INC": .single(TransitionConfig(
                        actions: [assign { ctx, _ in ctx.count += 1 }]
                    )),
                    "GO": .to("done"),
                ]),
                "done": StateNodeConfig(type: .final),
            ]
        ))
    }

    private func recordSession() -> ReplaySession {
        let recorder = InspectionRecorder()
        let actor = createActor(
            counterMachine,
            options: ActorOptions(inspect: recorder.observe())
        ).start(context: ReplayPersistContext(count: 0))

        actor.send(Event("INC"))
        actor.send(Event("GO"))

        guard let session = recorder.session() else {
            fatalError("Expected recorded session")
        }
        return session
    }

    @Test("ReplaySession survives JSON encode and decode")
    func jsonRoundTrip() throws {
        let session = recordSession()
        let data = try session.encodeJSON()
        let decoded = try ReplaySession.decodeJSON(data)

        #expect(decoded.rootId == session.rootId)
        #expect(decoded.machineId == session.machineId)
        #expect(decoded.steps.count == session.steps.count)
        #expect(decoded.replayEvents == session.replayEvents)
        #expect(decoded.finalSnapshot?.value == session.finalSnapshot?.value)
        #expect(decoded.allInspectionEvents.count == session.allInspectionEvents.count)
    }

    @Test("decoded session still verifies with pure replay")
    func verifyAfterDecode() throws {
        let session = recordSession()
        let decoded = try ReplaySession.decodeJSON(try session.encodeJSON())

        let verifications = verifyReplay(
            counterMachine,
            context: ReplayPersistContext(count: 0),
            session: decoded
        )
        #expect(verifications.filter { !$0.matches }.isEmpty)
    }
}