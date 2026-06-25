import Testing
import Foundation
@testable import SwiftXState

/// De-risks the eventual `Actor` migration: proves `Actor<MachineLogic>` matches `Actor` across
/// the *full* machine feature surface (compound + history, guards, parallel, raise, spawn), not just
/// the effect cases in `LogicActorTests`. If anything here diverged, the generic path couldn't yet
/// replace `Actor`.
@Suite("Actor<MachineLogic> full-feature parity")
struct LogicActorFullParityTests {

    /// Drives the same event sequence through `Actor` and `Actor<MachineLogic>`.
    private func driveBoth<C: Sendable>(
        _ machine: StateMachine<C>,
        _ events: [String]
    ) async -> (old: MachineSnapshot<C>, new: MachineSnapshot<C>) {
        let old = await createActor(machine).start()
        let new = await Actor(MachineLogic(machine: machine)).start()
        for e in events {
            await old.send(Event(e))
            await new.send(Event(e))
        }
        return (await old.snapshot, await new.snapshot)
    }

    @Test("compound states + shallow history")
    func compoundAndHistory() async {
        let machine = createMachine(MachineConfig(
            id: "power", initial: "on", context: EmptyContext(),
            states: [
                "on": StateNodeConfig(
                    initial: "first",
                    states: [
                        "first": StateNodeConfig(on: ["SWITCH": .to("second")]),
                        "second": StateNodeConfig(),
                        "hist": StateNodeConfig(type: .history, history: .shallow),
                    ],
                    on: ["POWER": .to("off")]
                ),
                "off": StateNodeConfig(on: ["POWER": .to("on.hist")]),
            ]
        ))
        let (old, new) = await driveBoth(machine, ["SWITCH", "POWER", "POWER"])
        #expect(old.value == new.value)
        #expect(new.value == .compound(["on": .atomic("second")]))
    }

    @Test("guards (inline + named via setup)")
    func guards() async {
        let machine = setup(
            guards: ["minElapsed": { $0.context.elapsed >= 100 && $0.context.elapsed < 200 }]
        ).createMachine(MachineConfig(
            initial: "green",
            context: LightContext(elapsed: 150),
            states: [
                "green": StateNodeConfig(on: [
                    "TIMER": .multiple([
                        TransitionConfig(target: "green", guard: .inline { $0.context.elapsed < 100 }),
                        TransitionConfig(target: "yellow", guard: .inline { $0.context.elapsed >= 100 && $0.context.elapsed < 200 }),
                    ]),
                ]),
                "yellow": StateNodeConfig(on: ["TIMER": .single(TransitionConfig(target: "red", guard: .named("minElapsed")))]),
                "red": StateNodeConfig(),
            ]
        ))
        let (old, new) = await driveBoth(machine, ["TIMER"])
        #expect(old.value == new.value)
        #expect(new.matches("yellow"))
    }

    @Test("parallel regions")
    func parallel() async {
        let machine = createMachine(MachineConfig(
            id: "fmt", initial: "active", context: EmptyContext(),
            states: [
                "active": StateNodeConfig(
                    type: .parallel,
                    states: [
                        "bold": StateNodeConfig(initial: "off", states: [
                            "off": StateNodeConfig(on: ["TOGGLE_BOLD": .to("on")]),
                            "on": StateNodeConfig(on: ["TOGGLE_BOLD": .to("off")]),
                        ]),
                        "italic": StateNodeConfig(initial: "off", states: [
                            "off": StateNodeConfig(on: ["TOGGLE_ITALIC": .to("on")]),
                            "on": StateNodeConfig(on: ["TOGGLE_ITALIC": .to("off")]),
                        ]),
                    ]
                ),
            ]
        ))
        let (old, new) = await driveBoth(machine, ["TOGGLE_BOLD"])
        #expect(old.value == new.value)
        #expect(new.matches("active.bold.on"))
        #expect(new.matches("active.italic.off"))
    }

    @Test("immediate raise chains within the macrostep")
    func immediateRaise() async {
        let machine = createMachine(MachineConfig(
            id: "chain", initial: "a", context: EmptyContext(),
            states: [
                "a": StateNodeConfig(on: ["GO": .single(TransitionConfig(target: "b", actions: [raise(Event("NEXT"))]))]),
                "b": StateNodeConfig(on: ["NEXT": .to("c")]),
                "c": StateNodeConfig(type: .final),
            ]
        ))
        let (old, new) = await driveBoth(machine, ["GO"])
        #expect(old.value == new.value)
        #expect(new.matches("c"))
        #expect(old.status == new.status)
        #expect(new.status == .done)
    }

    @Test("delayed raise defers via the scheduler (SimulatedClock)")
    func delayedRaise() async {
        // A *registered* delay key actually defers the raise (an unregistered numeric string is
        // treated as immediate by both runtimes — verified — so it wouldn't exercise the scheduler).
        let machine = setup(delays: ["short": { _ in 50 }]).createMachine(MachineConfig(
            id: "draise", initial: "idle", context: EmptyContext(),
            states: [
                "idle": StateNodeConfig(on: [
                    "GO": .single(TransitionConfig(target: "waiting", actions: [raise(Event("FIRE"), delay: "short")])),
                ]),
                "waiting": StateNodeConfig(on: ["FIRE": .to("done")]),
                "done": StateNodeConfig(type: .final),
            ]
        ))
        let clockOld = SimulatedClock()
        let clockNew = SimulatedClock()
        let old = await createActor(machine, options: ActorOptions(clock: clockOld)).start()
        let new = await Actor(MachineLogic(machine: machine), options: ActorOptions(clock: clockNew)).start()
        await old.send(Event("GO"))
        await new.send(Event("GO"))
        // Raise is deferred — both sit in `waiting` until the clock advances.
        #expect(await old.snapshot.matches("waiting"))
        #expect(await new.snapshot.matches("waiting"))
        clockOld.increment(60)
        clockNew.increment(60)
        await old.waitForSnapshot { $0.matches("done") }
        await new.waitForSnapshot { $0.matches("done") }
        #expect(await old.snapshot.value.description == new.snapshot.value.description)
        #expect(await new.status == .done)
    }

    @Test("spawnChild entry action populates children identically")
    func spawnChildParity() async {
        let child = createMachine(MachineConfig(initial: "running", context: EmptyContext(),
            states: ["running": StateNodeConfig()]))
        let spawner = createMachine(MachineConfig(
            id: "spawner", initial: "active", context: EmptyContext(),
            states: [
                "active": StateNodeConfig(entry: [spawnChild(fromMachine(child), id: "kid", inspectable: true)]),
            ]
        ))
        let old = await createActor(spawner).start()
        let new = await Actor(MachineLogic(machine: spawner)).start()
        let oldKeys = await old.snapshot.children.keys.sorted()
        let newKeys = await new.snapshot.children.keys.sorted()
        #expect(oldKeys == newKeys)
        #expect(newKeys == ["kid"])
    }
}
