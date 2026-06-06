import Testing
@testable import SwiftXState

struct LightContext: Sendable, Equatable {
    var elapsed: Int
}

@Suite("Guards")
struct GuardTests {
    func makeLightMachine(context: LightContext, initial: String = "green") -> StateMachine<LightContext> {
        setup(
            guards: [
                "minTimeElapsed": { args in
                    let elapsed = args.context.elapsed
                    return elapsed >= 100 && elapsed < 200
                },
            ]
        ).createMachine(MachineConfig(
            initial: initial,
            context: context,
            states: [
                "green": StateNodeConfig(on: [
                    "TIMER": .multiple([
                        TransitionConfig(
                            target: "green",
                            guard: .inline { $0.context.elapsed < 100 }
                        ),
                        TransitionConfig(
                            target: "yellow",
                            guard: .inline { $0.context.elapsed >= 100 && $0.context.elapsed < 200 }
                        ),
                    ]),
                    "EMERGENCY": .single(TransitionConfig(
                        target: "red",
                        guard: .inline { args in
                            (args.event as? EmergencyEvent)?.isEmergency == true
                        }
                    )),
                ]),
                "yellow": StateNodeConfig(on: [
                    "TIMER": .single(TransitionConfig(
                        target: "red",
                        guard: .named("minTimeElapsed")
                    )),
                ]),
                "red": StateNodeConfig(),
            ]
        ))
    }

    @Test("inline guard selects correct transition")
    func inlineGuard() {
        let machine = makeLightMachine(context: LightContext(elapsed: 0))
        var (snapshot, _) = initialTransition(machine)

        snapshot = transition(machine, snapshot: snapshot, event: Event("TIMER")).snapshot
        #expect(snapshot.matches("green"))

        let machine2 = makeLightMachine(context: LightContext(elapsed: 150))
        let (snap, _) = initialTransition(machine2)
        let (next, _) = transition(machine2, snapshot: snap, event: Event("TIMER"))
        #expect(next.matches("yellow"))
    }

    @Test("named guard")
    func namedGuard() {
        let machine = makeLightMachine(context: LightContext(elapsed: 150), initial: "yellow")
        let (snap, _) = initialTransition(machine)
        let (next, _) = transition(machine, snapshot: snap, event: Event("TIMER"))
        #expect(next.matches("red"))
    }

    @Test("stateIn guard matches active state")
    func stateInGuard() {
        let machine = createMachine(MachineConfig(
            initial: "green",
            context: LightContext(elapsed: 0),
            states: [
                "green": StateNodeConfig(on: [
                    "NEXT": .single(TransitionConfig(
                        target: "yellow",
                        guard: .composite(.stateIn("green"))
                    )),
                    "SKIP": .single(TransitionConfig(
                        target: "yellow",
                        guard: .composite(.stateIn("yellow"))
                    )),
                ]),
                "yellow": StateNodeConfig(),
            ]
        ))

        let (initial, _) = initialTransition(machine)
        let (allowed, _) = transition(machine, snapshot: initial, event: Event("NEXT"))
        let (blocked, _) = transition(machine, snapshot: initial, event: Event("SKIP"))

        #expect(allowed.matches("yellow"))
        #expect(blocked.matches("green"))
    }
}

struct EmergencyEvent: Eventable, Equatable {
    let type: String
    let isEmergency: Bool

    init(isEmergency: Bool) {
        self.type = "EMERGENCY"
        self.isEmergency = isEmergency
    }
}