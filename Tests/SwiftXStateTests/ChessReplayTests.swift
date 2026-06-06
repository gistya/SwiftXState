import Testing
@testable import SwiftXState

@Suite("Chess replay sample machine")
struct ChessReplayTests {
    @Test("recorded taps replay through time travel")
    func tapReplay() {
        let recorder = InspectionRecorder()
        let machine = ChessSampleMachine.make()

        let actor = createActor(
            machine,
            options: ActorOptions(inspect: recorder.observe())
        ).start(context: ChessSampleMachine.initialContext())

        actor.send(Event("TAP.6.4"))
        actor.send(Event("TAP.4.4"))

        guard let session = recorder.session() else {
            Issue.record("Expected recorded session")
            return
        }

        let atStart = timeTravel(
            machine,
            context: ChessSampleMachine.initialContext(),
            session: session,
            toStep: 0
        )
        #expect(atStart?.context.moves == 0)

        let afterFirst = timeTravel(
            machine,
            context: ChessSampleMachine.initialContext(),
            session: session,
            toStep: 1
        )
        #expect(afterFirst?.context.moves == 1)

        let verifications = verifyReplay(
            machine,
            context: ChessSampleMachine.initialContext(),
            session: session
        )
        #expect(verifications.filter { !$0.matches }.isEmpty)
    }
}

/// Minimal machine mirroring the sample app's TAP.* + replay encoding.
enum ChessSampleMachine {
    struct Context: Sendable, Equatable {
        var moves: Int
    }

    static func initialContext() -> Context {
        Context(moves: 0)
    }

    static func make() -> StateMachine<Context> {
        createMachine(MachineConfig(
            id: "chess-sample-test",
            initial: "playing",
            context: initialContext(),
            states: [
                "playing": StateNodeConfig(on: [
                    "TAP.*": .single(TransitionConfig(actions: [
                        assign { ctx, _ in ctx.moves += 1 },
                    ])),
                ]),
            ]
        ))
    }
}