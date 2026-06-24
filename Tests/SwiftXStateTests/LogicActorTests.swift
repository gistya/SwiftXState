import Testing
import Foundation
@testable import SwiftXState

/// A hand-written `ActorLogic` with no machine behind it — proves `LogicActor` is genuinely generic
/// over the reducer, not secretly machine-coupled.
private struct CounterLogic: ActorLogic {
    struct State: Sendable, Equatable {
        var count = 0
        var finished = false
    }
    let target: Int

    func initialState(input: SendableValue?) -> State {
        State(count: input?.get(Int.self) ?? 0, finished: false)
    }

    func step(_ snapshot: State, on event: any Eventable) -> State {
        var next = snapshot
        switch event.type {
        case "INC": next.count += 1
        case "DEC": next.count -= 1
        default: break
        }
        if next.count >= target { next.finished = true }
        return next
    }

    func status(of snapshot: State) -> SnapshotStatus {
        snapshot.finished ? .done : .active
    }
}

/// A *runnable* `ActorLogic`: it has no events to fold, it drives itself from `run`, pushing a
/// stream of snapshots and finishing. This is the shape behind callback / task / observable
/// children — proving `LogicActor` spans both reducer and runnable logics with one implementation.
private struct StreamLogic: ActorLogic {
    struct State: Sendable, Equatable {
        var value = 0
        var finished = false
    }
    let upTo: Int
    let done: TestSignal

    func initialState(input: SendableValue?) -> State { State() }
    func step(_ snapshot: State, on event: any Eventable) -> State { snapshot }
    func status(of snapshot: State) -> SnapshotStatus { snapshot.finished ? .done : .active }

    func run(_ scope: ActorScope<State>) async {
        for i in 1...upTo {
            await scope.update(State(value: i, finished: false))
        }
        await scope.update(State(value: upTo, finished: true))
        done.fire()
    }
}

@Suite("Generic LogicActor")
struct LogicActorTests {

    // MARK: hand-written reducer

    @Test("LogicActor runs a hand-written reducer")
    func handWrittenReducer() async {
        let actor = await LogicActor(CounterLogic(target: 3)).start()
        #expect(await actor.snapshot.count == 0)

        await actor.send(Event("INC"))
        await actor.send(Event("INC"))
        #expect(await actor.snapshot.count == 2)
        #expect(await actor.status == .active)

        await actor.send(Event("INC"))
        #expect(await actor.snapshot.count == 3)
        #expect(await actor.snapshot.finished)
        #expect(await actor.status == .done)
    }

    @Test("LogicActor honors run-to-completion status gate (no events after done)")
    func stopsAfterDone() async {
        let actor = await LogicActor(CounterLogic(target: 1)).start()
        await actor.send(Event("INC"))            // -> done
        #expect(await actor.status == .done)
        await actor.send(Event("INC"))            // ignored: not .active
        #expect(await actor.snapshot.count == 1)
    }

    @Test("LogicActor seeds initial state from input")
    func initialInput() async {
        let actor = await LogicActor(CounterLogic(target: 100)).start(input: SendableValue(10))
        #expect(await actor.snapshot.count == 10)
    }

    // MARK: runnable logic (background-driven snapshot stream)

    @Test("LogicActor drives a runnable logic to completion")
    func runnableLogic() async {
        let done = TestSignal()
        let actor = await LogicActor(StreamLogic(upTo: 5, done: done)).start()
        #expect(await done.wait())
        #expect(await actor.snapshot.value == 5)
        #expect(await actor.snapshot.finished)
        #expect(await actor.status == .done)
    }

    // MARK: same generic actor hosting MachineLogic (effect-free machines)

    @Test("LogicActor<MachineLogic> matches Actor on an always/final machine")
    func machineAlwaysParity() async {
        let gate = createMachine(MachineConfig(
            id: "gate", initial: "idle", context: EmptyContext(),
            states: [
                "idle": StateNodeConfig(on: ["GO": .to("checking")]),
                "checking": StateNodeConfig(always: [TransitionConfig(target: "open")]),
                "open": StateNodeConfig(type: .final),
            ]
        ))
        let old = await createActor(gate).start()
        let new = await LogicActor(MachineLogic(machine: gate)).start()
        await old.send(Event("GO"))
        await new.send(Event("GO"))

        #expect(await old.snapshot.value.description == new.snapshot.value.description)
        #expect(await new.snapshot.matches("open"))
        #expect(await old.status == new.status)
        #expect(await new.status == .done)
    }

    @Test("LogicActor<MachineLogic> matches Actor on an assign machine")
    func machineAssignParity() async {
        struct Ctx: Sendable, Equatable { var count = 0 }
        let counter = createMachine(MachineConfig(
            id: "counter", initial: "active", context: Ctx(),
            states: [
                "active": StateNodeConfig(on: [
                    "INC": .single(TransitionConfig(actions: [assign { ctx, _ in ctx.count += 1 }])),
                ]),
            ]
        ))
        let old = await createActor(counter).start()
        let new = await LogicActor(MachineLogic(machine: counter)).start()
        for _ in 0..<4 {
            await old.send(Event("INC"))
            await new.send(Event("INC"))
        }
        let oldCtx = await old.snapshot.context
        let newCtx = await new.snapshot.context
        #expect(oldCtx == newCtx)
        #expect(newCtx.count == 4)
    }
}
