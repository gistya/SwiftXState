import Testing
@testable import SwiftXState

/// Mirrors SwiftXChess parallel layout: `game` compound + `castling` parallel region.
@Suite("Chess parallel replay scrub")
struct ChessParallelReplayTests {
    struct Context: Sendable, Equatable, Codable {
        var moves: Int
        var replayStep: Int
        var replaySession: ReplaySession?
    }

    private var machine: StateMachine<Context> {
        createMachine(
            MachineConfig(
                id: "chess-parallel-replay-test",
                context: Context(moves: 0, replayStep: 0, replaySession: nil),
                states: [
                    "game": StateNodeConfig(
                        initial: "playing",
                        states: [
                            "playing": StateNodeConfig(on: [
                                "TAP.*": .single(TransitionConfig(actions: [
                                    assign { ctx, _ in ctx.moves += 1 },
                                ])),
                                "ENTER_REPLAY": .single(TransitionConfig(
                                    target: "replaying",
                                    actions: [assign { ctx, _ in
                                        ctx.replayStep = 0
                                    }]
                                )),
                            ]),
                            "replaying": StateNodeConfig(on: [
                                "EXIT_REPLAY": .to("playing"),
                                "REPLAY_SCRUB.*": .single(TransitionConfig(actions: [
                                    assign { ctx, args in
                                        guard let step = parseScrubStep(args.event) else { return }
                                        ctx.replayStep = step
                                        ctx.moves = step
                                    },
                                ])),
                            ]),
                        ]
                    ),
                    "castling": StateNodeConfig(
                        type: .parallel,
                        states: [
                            "sideA": StateNodeConfig(
                                initial: "available",
                                states: [
                                    "available": StateNodeConfig(on: [
                                        "TAP.*": .to("forfeited"),
                                    ]),
                                    "forfeited": StateNodeConfig(),
                                ]
                            ),
                            "sideB": StateNodeConfig(
                                initial: "available",
                                states: [
                                    "available": StateNodeConfig(),
                                    "forfeited": StateNodeConfig(),
                                ]
                            ),
                        ]
                    ),
                ],
                type: .parallel
            )
        )
    }

    @Test("REPLAY_SCRUB updates context while in replaying")
    func replayScrubInParallelMachine() {
        let recorder = InspectionRecorder()
        let actor = createActor(
            machine,
            options: ActorOptions(inspect: recorder.observe())
        ).start()

        actor.send(Event("TAP.0"))
        actor.send(Event("TAP.0"))
        actor.send(Event("TAP.0"))

        guard let session = recorder.session() else {
            Issue.record("Expected recorded session")
            return
        }

        actor.send(Event("ENTER_REPLAY"))
        #expect(actor.snapshot.context.replayStep == 0)
        #expect(actor.snapshot.matches("game.replaying"))

        actor.send(Event("REPLAY_SCRUB.1"))
        #expect(actor.snapshot.context.replayStep == 1)
        #expect(actor.snapshot.context.moves == 1)

        actor.send(Event("REPLAY_SCRUB.0"))
        #expect(actor.snapshot.context.replayStep == 0)
        #expect(actor.snapshot.context.moves == 0)

        let traveled = timeTravel(
            machine,
            context: Context(moves: 0, replayStep: 0, replaySession: nil),
            session: session,
            toStep: 2
        )
        #expect(traveled?.context.moves == 2)
    }

    private func parseScrubStep(_ event: any Eventable) -> Int? {
        let parts = event.type.split(separator: ".")
        guard parts.count == 2, let step = Int(parts[1]) else { return nil }
        return step
    }
}