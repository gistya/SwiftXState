import Testing
@testable import SwiftXState

private struct DelayContext: Sendable, Equatable {
    var delay: Int
}

@Suite("Delayed transitions")
struct AfterTests {
    private var lightMachine: StateMachine<EmptyContext> {
        createMachine(MachineConfig(
            id: "light",
            initial: "green",
            context: EmptyContext(),
            states: [
                "green": StateNodeConfig(after: [
                    "1000": .to("yellow"),
                ]),
                "yellow": StateNodeConfig(after: [
                    "1000": .single(TransitionConfig(target: "red")),
                ]),
                "red": StateNodeConfig(after: [
                    "1000": .to("green"),
                ]),
            ]
        ))
    }

    @Test("transitions after delay")
    func transitionsAfterDelay() {
        let clock = SimulatedClock()
        let actor = createActor(lightMachine, options: ActorOptions(clock: clock)).start()

        #expect(actor.snapshot.matches("green"))

        clock.increment(500)
        #expect(actor.snapshot.matches("green"))

        clock.increment(510)
        #expect(actor.snapshot.matches("yellow"))
    }

    @Test("registers after event types on state node")
    func afterEventTypes() {
        let greenNode = lightMachine.states["green"]!
        let eventTypes = Array(greenNode.transitions.keys)

        #expect(eventTypes == ["xstate.after.1000.light.green"])
    }

    @Test("cancels timer when leaving state before delay elapses")
    func cancelsOnExit() {
        let clock = SimulatedClock()
        let machine = createMachine(MachineConfig(
            initial: "waiting",
            context: EmptyContext(),
            states: [
                "waiting": StateNodeConfig(
                    on: ["SKIP": .to("skipped")],
                    after: ["1000": .to("done")]
                ),
                "done": StateNodeConfig(),
                "skipped": StateNodeConfig(),
            ]
        ))

        let actor = createActor(machine, options: ActorOptions(clock: clock)).start()
        actor.send(Event("SKIP"))

        #expect(actor.snapshot.matches("skipped"))

        clock.increment(2000)
        #expect(actor.snapshot.matches("skipped"))
    }

    @Test("reschedules timer when re-entering state")
    func reschedulesOnReentry() {
        let clock = SimulatedClock()
        let machine = createMachine(MachineConfig(
            initial: "waiting",
            context: EmptyContext(),
            states: [
                "waiting": StateNodeConfig(
                    on: ["PAUSE": .to("paused")],
                    after: ["1000": .to("done")]
                ),
                "paused": StateNodeConfig(
                    on: ["RESUME": .to("waiting")]
                ),
                "done": StateNodeConfig(),
            ]
        ))

        let actor = createActor(machine, options: ActorOptions(clock: clock)).start()

        clock.increment(500)
        actor.send(Event("PAUSE"))

        clock.increment(500)
        #expect(actor.snapshot.matches("paused"))

        actor.send(Event("RESUME"))

        clock.increment(500)
        #expect(actor.snapshot.matches("waiting"))

        clock.increment(510)
        #expect(actor.snapshot.matches("done"))
    }

    @Test("supports guarded after transitions")
    func guardedAfterTransition() {
        let clock = SimulatedClock()
        let machine = setup(
            guards: [
                "yes": { _ in true },
            ]
        ).createMachine(MachineConfig(
            initial: "x",
            context: EmptyContext(),
            states: [
                "x": StateNodeConfig(after: [
                    "1": .multiple([
                        TransitionConfig(target: "y", guard: .named("yes")),
                        TransitionConfig(target: "z"),
                    ]),
                ]),
                "y": StateNodeConfig(),
                "z": StateNodeConfig(),
            ]
        ))

        let actor = createActor(machine, options: ActorOptions(clock: clock)).start()
        clock.increment(10)

        #expect(actor.snapshot.matches("y"))
    }

    @Test("supports named delay expressions")
    func namedDelay() {
        let clock = SimulatedClock()
        let resolved = DelayBox()

        let machine = createMachine(
            MachineConfig(
                initial: "inactive",
                context: DelayContext(delay: 500),
                states: [
                    "inactive": StateNodeConfig(after: [
                        "myDelay": .to("active"),
                    ]),
                    "active": StateNodeConfig(),
                ]
            ),
            implementations: MachineImplementations(
                delays: [
                    "myDelay": { args in
                        resolved.value = args.context
                        return args.context.delay
                    },
                ]
            )
        )

        let actor = createActor(machine, options: ActorOptions(clock: clock)).start()
        #expect(resolved.value == DelayContext(delay: 500))
        #expect(actor.snapshot.matches("inactive"))

        clock.increment(300)
        #expect(actor.snapshot.matches("inactive"))

        clock.increment(200)
        #expect(actor.snapshot.matches("active"))
    }

    @Test("pure transition handles after events")
    func pureAfterTransition() {
        let machine = createMachine(MachineConfig(
            initial: "a",
            context: EmptyContext(),
            states: [
                "a": StateNodeConfig(after: ["10": .to("b")]),
                "b": StateNodeConfig(),
            ]
        ))

        let (initial, _) = SwiftXState.initialTransition(machine)
        let afterEvent = Event(createAfterEvent(delayRef: "10", stateNodeId: "(machine).a"))
        let (next, _) = SwiftXState.transition(machine, snapshot: initial, event: afterEvent)

        #expect(next.matches("b"))
    }
}

private final class DelayBox: @unchecked Sendable {
    var value: DelayContext?
}