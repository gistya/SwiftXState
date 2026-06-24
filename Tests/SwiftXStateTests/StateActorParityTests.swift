import Testing
import Foundation
@testable import SwiftXState

/// Deterministic snapshot wait for the experimental `StateActor`, mirroring the `Actor` helper in
/// `TestAsyncSupport` (uses `subscribe`, no sleeps).
extension StateActor {
    @discardableResult
    func waitForSnapshot(
        timeout: Duration = .seconds(5),
        where predicate: @escaping @Sendable (MachineSnapshot<Context>) -> Bool
    ) async -> MachineSnapshot<Context>? {
        let oneShot = OneShot<MachineSnapshot<Context>?>()
        let subscription = subscribe { snapshot in
            if predicate(snapshot) { oneShot.resolve(snapshot) }
        }
        defer { subscription.cancel() }
        let timeoutTask = Task {
            try? await Task.sleep(for: timeout)
            oneShot.resolve(nil)
        }
        defer { timeoutTask.cancel() }
        return await oneShot.get()
    }
}

private struct Counter: Sendable, Equatable { var count = 0 }
private struct RelayContext: Sendable, Equatable { var gotPong: Bool; var childId: String }
private struct ParentCtx: Sendable, Equatable { var userName: String? }
private struct ChildCtx: Sendable, Equatable { var userName: String? }

/// Drives the **same** machine + event sequence through the legacy `Actor` and the new
/// `StateActor`, asserting they land on the same state value and lifecycle status. This is the
/// proof that `StateActor` reaches parity over the shared runtime (DelayScheduler / ChildRegistry /
/// ActionEffectRunner / child factory) — not a reimplementation that merely looks similar.
@Suite("StateActor parity with Actor")
struct StateActorParityTests {

    private func expectSameValueAndStatus<C: Sendable>(
        _ old: MachineSnapshot<C>,
        _ new: MachineSnapshot<C>,
        _ label: String
    ) {
        #expect(old.value.description == new.value.description, "\(label): value")
        #expect(old.status == new.status, "\(label): status")
    }

    // MARK: transition + always (eventless macrostep)

    @Test("transition and always reach the same value")
    func transitionAndAlways() async {
        let gate = createMachine(MachineConfig(
            id: "gate", initial: "idle", context: EmptyContext(),
            states: [
                "idle": StateNodeConfig(on: ["GO": .to("checking")]),
                "checking": StateNodeConfig(always: [TransitionConfig(target: "open")]),
                "open": StateNodeConfig(type: .final),
            ]
        ))
        let old = await createActor(gate).start()
        let new = await StateActor(gate).start()
        await old.send(Event("GO"))
        await new.send(Event("GO"))
        expectSameValueAndStatus(await old.snapshot, await new.snapshot, "gate")
        #expect(await new.snapshot.matches("open"))
        #expect(await new.snapshot.status == .done)
    }

    // MARK: assign (context mutation across a macrostep)

    @Test("assign mutates context identically")
    func assignParity() async {
        let counter = createMachine(MachineConfig(
            id: "counter", initial: "active", context: Counter(),
            states: [
                "active": StateNodeConfig(on: [
                    "INC": .single(TransitionConfig(actions: [assign { ctx, _ in ctx.count += 1 }])),
                ]),
            ]
        ))
        let old = await createActor(counter).start()
        let new = await StateActor(counter).start()
        for _ in 0..<5 {
            await old.send(Event("INC"))
            await new.send(Event("INC"))
        }
        let oldCtx = await old.snapshot.context
        let newCtx = await new.snapshot.context
        #expect(oldCtx == newCtx)
        #expect(newCtx.count == 5)
    }

    // MARK: emit

    @Test("emit delivers to on() listeners identically")
    func emitParity() async {
        let emitter = createMachine(MachineConfig(
            id: "emitter", initial: "idle", context: EmptyContext(),
            states: [
                "idle": StateNodeConfig(on: [
                    "GO": .single(TransitionConfig(actions: [emit("ping")])),
                ]),
            ]
        ))
        let old = await createActor(emitter).start()
        let new = await StateActor(emitter).start()

        let oldFired = TestSignal()
        let newFired = TestSignal()
        await old.on("ping") { _ in oldFired.fire() }
        await new.on("ping") { _ in newFired.fire() }

        await old.send(Event("GO"))
        await new.send(Event("GO"))

        #expect(await oldFired.wait())
        #expect(await newFired.wait())
    }

    // MARK: after (delayed transition, deterministic SimulatedClock)

    @Test("after fires the delayed transition identically")
    func afterParity() async {
        let timed = createMachine(MachineConfig(
            id: "timed", initial: "waiting", context: EmptyContext(),
            states: [
                "waiting": StateNodeConfig(after: ["20": .to("done")]),
                "done": StateNodeConfig(type: .final),
            ]
        ))
        let clockOld = SimulatedClock()
        let clockNew = SimulatedClock()
        let old = await createActor(timed, options: ActorOptions(clock: clockOld)).start()
        let new = await StateActor(timed, options: ActorOptions(clock: clockNew)).start()

        #expect(await old.snapshot.matches("waiting"))
        #expect(await new.snapshot.matches("waiting"))

        clockOld.increment(25)
        clockNew.increment(25)

        await old.waitForSnapshot { $0.matches("done") }
        await new.waitForSnapshot { $0.matches("done") }
        expectSameValueAndStatus(await old.snapshot, await new.snapshot, "after")
        #expect(await new.snapshot.status == .done)
    }

    // MARK: invoke (child machine onDone → parent context)

    @Test("invoke onDone feeds parent context identically")
    func invokeOnDoneParity() async {
        func makeParent() -> StateMachine<ParentCtx> {
            let child = createMachine(MachineConfig(
                initial: "done", context: ChildCtx(userName: "Ada"),
                states: [
                    "done": StateNodeConfig(
                        type: .final,
                        output: { args in SendableValue(args.context.userName ?? "") }
                    ),
                ]
            ))
            return createMachine(MachineConfig(
                id: "fetcher", initial: "idle", context: ParentCtx(userName: nil),
                states: [
                    "idle": StateNodeConfig(on: ["GO": .to("waiting")]),
                    "waiting": StateNodeConfig(invoke: [
                        InvokeConfig(
                            id: "fetch",
                            src: .machine(MachineActorLogicBox(child) { _ in ChildCtx(userName: "Ada") }),
                            onDone: .single(TransitionConfig(
                                target: "received",
                                actions: [assign { ctx, args in
                                    if let event = args.event as? DoneActorEvent {
                                        ctx.userName = event.output?.get(String.self)
                                    }
                                }]
                            ))
                        ),
                    ]),
                    "received": StateNodeConfig(type: .final),
                ]
            ))
        }

        let old = await createActor(makeParent()).start()
        let new = await StateActor(makeParent()).start()
        await old.send(Event("GO"))
        await new.send(Event("GO"))

        await old.waitForSnapshot { $0.matches("received") }
        await new.waitForSnapshot { $0.matches("received") }

        let oldCtx = await old.snapshot.context
        let newCtx = await new.snapshot.context
        expectSameValueAndStatus(await old.snapshot, await new.snapshot, "invoke")
        #expect(oldCtx == newCtx)
        #expect(newCtx.userName == "Ada")
    }

    // MARK: invoke + forwardTo + child→parent (sendToParent)

    @Test("forwardTo to an invoked child round-trips identically")
    func forwardToParity() async {
        func makeRelay() -> StateMachine<RelayContext> {
            createMachine(MachineConfig(
                initial: "active", context: RelayContext(gotPong: false, childId: "listener"),
                states: [
                    "active": StateNodeConfig(
                        on: [
                            "PING": .single(TransitionConfig(actions: [forwardTo("listener")])),
                            "PONG": .single(TransitionConfig(actions: [assign { ctx, _ in ctx.gotPong = true }])),
                        ],
                        invoke: [
                            InvokeConfig(
                                id: "listener",
                                src: fromCallback { scope in
                                    scope.receive { event in
                                        if event.type == "PING" { scope.sendToParent(Event("PONG")) }
                                    }
                                    return nil
                                }
                            ),
                        ]
                    ),
                ]
            ))
        }

        let old = await createActor(makeRelay()).start()
        let new = await StateActor(makeRelay()).start()
        await old.send(Event("PING"))
        await new.send(Event("PING"))

        await old.waitForSnapshot { $0.context.gotPong }
        await new.waitForSnapshot { $0.context.gotPong }

        #expect(await old.snapshot.context.gotPong)
        #expect(await new.snapshot.context.gotPong)
    }
}
