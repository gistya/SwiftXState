import Testing
@testable import SwiftXState

private struct ParallelContext: Sendable, Equatable {
    var modeCount: Int
    var themeCount: Int
}

@Suite("Parallel multi-transition")
struct ParallelTransitionTests {
    private var parallelMachine: StateMachine<ParallelContext> {
        createMachine(MachineConfig(
            context: ParallelContext(modeCount: 0, themeCount: 0),
            states: [
                "mode": StateNodeConfig(
                    initial: "light",
                    states: [
                        "light": StateNodeConfig(on: [
                            "SYNC": .to("dark"),
                        ]),
                        "dark": StateNodeConfig(on: [
                            "SYNC": .to("light"),
                        ]),
                    ]
                ),
                "theme": StateNodeConfig(
                    initial: "default",
                    states: [
                        "default": StateNodeConfig(on: [
                            "SYNC": .to("custom"),
                        ]),
                        "custom": StateNodeConfig(on: [
                            "SYNC": .to("default"),
                        ]),
                    ]
                ),
            ],
            type: .parallel
        ))
    }

    @Test("parallel machine starts in all regions")
    func parallelInitialState() {
        let (snapshot, _) = initialTransition(parallelMachine)

        #expect(snapshot.matches(StateValue.compound([
            "mode": .atomic("light"),
            "theme": .atomic("default"),
        ])))
    }

    @Test("selectTransitions returns one transition per parallel region")
    func selectTransitionsPerRegion() {
        let (snapshot, _) = initialTransition(parallelMachine)
        let transitions = selectTransitions(event: Event("SYNC"), snapshot: snapshot)
        #expect(transitions.count == 2)
    }

    @Test("parallel regions transition together on the same event")
    func parallelRegionsTogether() {
        let actor = createActor(parallelMachine).start()
        actor.send(Event("SYNC"))

        #expect(actor.snapshot.matches(StateValue.compound([
            "mode": .atomic("dark"),
            "theme": .atomic("custom"),
        ])))
    }

    @Test("multi-target transition updates multiple parallel regions")
    func multiTargetTransition() {
        let machine: StateMachine<ParallelContext> = createMachine(MachineConfig(
            context: ParallelContext(modeCount: 0, themeCount: 0),
            states: [
                "mode": StateNodeConfig(
                    initial: "light",
                    states: [
                        "light": StateNodeConfig(),
                        "dark": StateNodeConfig(),
                    ]
                ),
                "theme": StateNodeConfig(
                    initial: "default",
                    states: [
                        "default": StateNodeConfig(),
                        "custom": StateNodeConfig(),
                    ]
                ),
            ],
            on: [
                "SET_DARK_CUSTOM": .single(TransitionConfig(
                    targets: [".mode.dark", ".theme.custom"]
                )),
            ],
            type: .parallel
        ))

        let actor = createActor(machine).start()
        actor.send(Event("SET_DARK_CUSTOM"))

        #expect(actor.snapshot.matches(StateValue.compound([
            "mode": .atomic("dark"),
            "theme": .atomic("custom"),
        ])))
    }

    @Test("deepest handler wins when parent and child both handle an event")
    func deepestHandlerWins() {
        let machine: StateMachine<ParallelContext> = createMachine(MachineConfig(
            initial: "parent",
            context: ParallelContext(modeCount: 0, themeCount: 0),
            states: [
                "parent": StateNodeConfig(
                    initial: "child",
                    states: [
                        "child": StateNodeConfig(on: [
                            "GO": .to("childTarget"),
                        ]),
                        "parentTarget": StateNodeConfig(),
                        "childTarget": StateNodeConfig(),
                    ],
                    on: [
                        "GO": .to("parentTarget"),
                    ]
                ),
            ]
        ))

        let actor = createActor(machine).start()
        actor.send(Event("GO"))

        #expect(actor.snapshot.matches(StateValue.compound([
            "parent": .atomic("childTarget"),
        ])))
    }

    @Test("parallel transition actions run for each selected transition")
    func parallelTransitionActions() {
        let machine: StateMachine<ParallelContext> = createMachine(MachineConfig(
            context: ParallelContext(modeCount: 0, themeCount: 0),
            states: [
                "mode": StateNodeConfig(
                    initial: "light",
                    states: [
                        "light": StateNodeConfig(on: [
                            "SYNC": .single(TransitionConfig(
                                target: "dark",
                                actions: [assign { ctx, _ in ctx.modeCount += 1 }]
                            )),
                        ]),
                        "dark": StateNodeConfig(),
                    ]
                ),
                "theme": StateNodeConfig(
                    initial: "default",
                    states: [
                        "default": StateNodeConfig(on: [
                            "SYNC": .single(TransitionConfig(
                                target: "custom",
                                actions: [assign { ctx, _ in ctx.themeCount += 1 }]
                            )),
                        ]),
                        "custom": StateNodeConfig(),
                    ]
                ),
            ],
            type: .parallel
        ))

        let actor = createActor(machine).start()
        actor.send(Event("SYNC"))

        #expect(actor.snapshot.context.modeCount == 1)
        #expect(actor.snapshot.context.themeCount == 1)
    }
}