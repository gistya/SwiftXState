import Testing
@testable import SwiftXState

private struct StopContext: Sendable, Equatable {
    var step: Int
}

@Suite("Actor.stop teardown")
struct ActorStopTeardownTests {
    /// A delay scheduled before `stop()` must not take effect afterwards.
    ///
    /// Note this already held before `stop()` learned to cancel timers, and by a somewhat indirect
    /// route: `fireSelfEvent` appends straight to the mailbox and drains, bypassing the `isStopped`
    /// check that `send(_:)` applies — but `process(_:)` then drops the event because `stop()` has
    /// already replaced `_snapshot` with a terminal one. The behaviour is correct; it just rests on
    /// a second line of defence rather than the first. These tests pin it down so a future change to
    /// either guard cannot quietly regress it.
    ///
    /// The wait is unavoidable here: the assertion is that something *never* happens, which needs a
    /// window longer than the delay. It mirrors the existing "cancel prevents a delayed raise from
    /// firing" test rather than inventing a second idiom.
    @Test("a delayed raise scheduled before stop does not fire after it")
    func delayedRaiseDoesNotFireAfterStop() async {
        let machine = createMachine(MachineConfig(
            initial: "idle",
            context: StopContext(step: 0),
            states: [
                "idle": StateNodeConfig(on: [
                    "ARM": .single(TransitionConfig(
                        actions: [raise(Event("FIRE"), delay: 100, id: "fire-timer")]
                    )),
                    "FIRE": .single(TransitionConfig(
                        target: "done",
                        actions: [assign { ctx, _ in ctx.step = 1 }]
                    )),
                ]),
                "done": StateNodeConfig(type: .final),
            ]
        ))

        let actor = await createActor(machine).start()
        await actor.send(Event("ARM"))
        await actor.stop()

        try? await Task.sleep(for: .milliseconds(150))

        #expect(await actor.snapshot.context.step == 0)
        #expect(await !actor.snapshot.matches("done"))
    }

    /// The child-directed variant of the same timer: `sendTo(..., delay:)` must also not deliver
    /// after the scheduling actor has stopped.
    @Test("a delayed self-event with a long delay is cancelled by stop")
    func longDelayCancelledByStop() async {
        let machine = createMachine(MachineConfig(
            initial: "idle",
            context: StopContext(step: 0),
            states: [
                "idle": StateNodeConfig(on: [
                    "ARM": .single(TransitionConfig(
                        actions: [raise(Event("FIRE"), delay: 50, id: "t")]
                    )),
                    "FIRE": .single(TransitionConfig(
                        actions: [assign { ctx, _ in ctx.step = 99 }]
                    )),
                ]),
            ]
        ))

        let actor = await createActor(machine).start()
        await actor.send(Event("ARM"))
        await actor.stop()

        try? await Task.sleep(for: .milliseconds(120))

        #expect(await actor.snapshot.context.step == 0)
    }
}
