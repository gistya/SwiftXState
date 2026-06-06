import Testing
@testable import SwiftXState

private struct WildcardContext: Sendable, Equatable {
    var lastEvent: String?
}

@Suite("Wildcard transitions")
struct WildcardTests {
    @Test("full wildcard catches unhandled events")
    func fullWildcard() {
        let machine = createMachine(MachineConfig(
            initial: "asleep",
            context: WildcardContext(lastEvent: nil),
            states: [
                "asleep": StateNodeConfig(on: [
                    "*": .to("awake"),
                ]),
                "awake": StateNodeConfig(),
            ]
        ))

        let actor = createActor(machine).start()
        actor.send(Event("anything"))

        #expect(actor.snapshot.matches("awake"))
    }

    @Test("exact transition takes priority over full wildcard")
    func exactOverWildcard() {
        let machine = createMachine(MachineConfig(
            initial: "idle",
            context: WildcardContext(lastEvent: nil),
            states: [
                "idle": StateNodeConfig(on: [
                    "GO": .to("handled"),
                    "*": .to("caught"),
                ]),
                "handled": StateNodeConfig(),
                "caught": StateNodeConfig(),
            ]
        ))

        let actor = createActor(machine).start()
        actor.send(Event("GO"))

        #expect(actor.snapshot.matches("handled"))
    }

    @Test("full wildcard used when exact guard fails")
    func wildcardWhenGuardFails() {
        let machine = createMachine(MachineConfig(
            initial: "idle",
            context: WildcardContext(lastEvent: nil),
            states: [
                "idle": StateNodeConfig(on: [
                    "GO": .single(TransitionConfig(
                        target: "blocked",
                        guard: .inline { _ in false }
                    )),
                    "*": .to("caught"),
                ]),
                "blocked": StateNodeConfig(),
                "caught": StateNodeConfig(),
            ]
        ))

        let actor = createActor(machine).start()
        actor.send(Event("GO"))

        #expect(actor.snapshot.matches("caught"))
    }

    @Test("partial wildcard matches event prefix")
    func partialWildcard() {
        let machine = createMachine(MachineConfig(
            initial: "prompt",
            context: WildcardContext(lastEvent: nil),
            states: [
                "prompt": StateNodeConfig(on: [
                    "feedback.*": .to("form"),
                ]),
                "form": StateNodeConfig(),
            ]
        ))

        let actor = createActor(machine).start()
        actor.send(Event("feedback.good"))

        #expect(actor.snapshot.matches("form"))
    }

    @Test("partial wildcard matches base event without suffix")
    func partialWildcardBaseEvent() {
        let machine = createMachine(MachineConfig(
            initial: "prompt",
            context: WildcardContext(lastEvent: nil),
            states: [
                "prompt": StateNodeConfig(on: [
                    "feedback.*": .to("form"),
                ]),
                "form": StateNodeConfig(),
            ]
        ))

        let actor = createActor(machine).start()
        actor.send(Event("feedback"))

        #expect(actor.snapshot.matches("form"))
    }

    @Test("partial wildcard does not match unrelated events")
    func partialWildcardNoMatch() {
        let machine = createMachine(MachineConfig(
            initial: "prompt",
            context: WildcardContext(lastEvent: nil),
            states: [
                "prompt": StateNodeConfig(on: [
                    "feedback.*": .to("form"),
                ]),
                "form": StateNodeConfig(),
            ]
        ))

        let actor = createActor(machine).start()
        actor.send(Event("other"))

        #expect(actor.snapshot.matches("prompt"))
    }

    @Test("wildcard descriptors are excluded from machine.events")
    func eventsExcludeWildcards() {
        let machine = createMachine(MachineConfig(
            initial: "idle",
            context: WildcardContext(lastEvent: nil),
            states: [
                "idle": StateNodeConfig(on: [
                    "GO": .to("done"),
                    "feedback.*": .to("done"),
                    "*": .to("done"),
                ]),
                "done": StateNodeConfig(),
            ]
        ))

        #expect(machine.events == ["GO"])
    }

    @Test("snapshot.can reflects wildcard transitions")
    func canWildcard() {
        let machine = createMachine(MachineConfig(
            initial: "idle",
            context: WildcardContext(lastEvent: nil),
            states: [
                "idle": StateNodeConfig(on: [
                    "*": .to("done"),
                ]),
                "done": StateNodeConfig(),
            ]
        ))

        let (snapshot, _) = SwiftXState.initialTransition(machine)
        #expect(snapshot.can(Event("anything")))
    }
}