import Testing
@testable import SwiftXState

private struct ReplayCounterContext: Sendable, Equatable {
    var count: Int
}

@Suite("Recording and replay (devtools v2)")
struct ReplayTests {
    @Test("InspectionRecorder captures transition steps")
    func recorderCapturesSteps() {
        let recorder = InspectionRecorder()

        let machine = createMachine(MachineConfig(
            initial: "idle",
            context: ReplayCounterContext(count: 0),
            states: [
                "idle": StateNodeConfig(on: [
                    "INC": .single(TransitionConfig(
                        actions: [assign { ctx, _ in ctx.count += 1 }]
                    )),
                    "GO": .to("done"),
                ]),
                "done": StateNodeConfig(type: .final),
            ]
        ))

        let actor = createActor(
            machine,
            options: ActorOptions(inspect: recorder.observe())
        ).start(context: ReplayCounterContext(count: 0))

        actor.send(Event("INC"))
        actor.send(Event("GO"))

        let session = recorder.session()
        #expect(session != nil)
        #expect(session?.steps.count == 3) // init + INC + GO
        #expect(session?.replayEvents.count == 2) // INC + GO
        #expect(session?.finalSnapshot?.value == "done")
        #expect(session?.steps.last?.actionTypes.isEmpty == true)
    }

    @Test("pure replay matches recorded session")
    func verifyPureReplay() {
        let recorder = InspectionRecorder()

        let machine = createMachine(MachineConfig(
            initial: "idle",
            context: ReplayCounterContext(count: 0),
            states: [
                "idle": StateNodeConfig(on: [
                    "INC": .single(TransitionConfig(
                        actions: [assign { ctx, _ in ctx.count += 1 }]
                    )),
                    "GO": .to("done"),
                ]),
                "done": StateNodeConfig(type: .final),
            ]
        ))

        let actor = createActor(
            machine,
            options: ActorOptions(inspect: recorder.observe())
        ).start(context: ReplayCounterContext(count: 0))

        actor.send(Event("INC"))
        actor.send(Event("GO"))

        guard let session = recorder.session() else {
            Issue.record("Expected recorded session")
            return
        }

        let verifications = verifyReplay(machine, context: ReplayCounterContext(count: 0), session: session)
        #expect(verifications.filter { !$0.matches }.isEmpty)
    }

    @Test("timeTravel returns snapshot at step")
    func timeTravelToStep() {
        let recorder = InspectionRecorder()

        let machine = createMachine(MachineConfig(
            initial: "idle",
            context: ReplayCounterContext(count: 0),
            states: [
                "idle": StateNodeConfig(on: [
                    "INC": .single(TransitionConfig(
                        actions: [assign { ctx, _ in ctx.count += 1 }]
                    )),
                    "GO": .to("done"),
                ]),
                "done": StateNodeConfig(type: .final),
            ]
        ))

        let actor = createActor(
            machine,
            options: ActorOptions(inspect: recorder.observe())
        ).start(context: ReplayCounterContext(count: 0))

        actor.send(Event("INC"))
        actor.send(Event("GO"))

        guard let session = recorder.session() else {
            Issue.record("Expected recorded session")
            return
        }

        let atInc = timeTravel(machine, context: ReplayCounterContext(count: 0), session: session, toStep: 1)
        #expect(atInc?.context.count == 1)
        #expect(atInc?.matches("idle") == true)

        let atDone = timeTravel(machine, context: ReplayCounterContext(count: 0), session: session, toStep: 2)
        #expect(atDone?.matches("done") == true)
        #expect(atDone?.status == .done)
    }

    @Test("live actor replay matches recording")
    func liveActorReplay() {
        let recorder = InspectionRecorder()

        let machine = createMachine(MachineConfig(
            initial: "idle",
            context: ReplayCounterContext(count: 0),
            states: [
                "idle": StateNodeConfig(on: [
                    "INC": .single(TransitionConfig(
                        actions: [assign { ctx, _ in ctx.count += 1 }]
                    )),
                    "GO": .to("done"),
                ]),
                "done": StateNodeConfig(type: .final),
            ]
        ))

        let recordedActor = createActor(
            machine,
            options: ActorOptions(inspect: recorder.observe())
        ).start(context: ReplayCounterContext(count: 0))
        recordedActor.send(Event("INC"))
        recordedActor.send(Event("GO"))

        guard let session = recorder.session() else {
            Issue.record("Expected recorded session")
            return
        }

        let (replayedActor, verifications) = replayActor(
            machine,
            context: ReplayCounterContext(count: 0),
            session: session
        )

        #expect(verifications.filter { !$0.matches }.isEmpty)
        #expect(replayedActor.snapshot.matches("done"))
        #expect(replayedActor.snapshot.context.count == 1)
    }

    @Test("StoreRecorder captures and replays store session")
    func storeRecorder() {
        let recorder = StoreRecorder<ReplayCounterContext, Event>()

        let store = Store<ReplayCounterContext, Event>(
            StoreConfig(
                context: ReplayCounterContext(count: 0),
                on: [
                    "INC": { @Sendable ctx, _ in ctx.count += 1 },
                    "DEC": { @Sendable ctx, _ in ctx.count -= 1 },
                ]
            )
        )

        recorder.send(store, event: Event("INC"))
        recorder.send(store, event: Event("INC"))
        recorder.send(store, event: Event("DEC"))

        guard let session = recorder.session() else {
            Issue.record("Expected store session")
            return
        }

        #expect(session.steps.count == 3)
        #expect(session.steps.last?.snapshotAfter.context.count == 1)

        let events = [
            Event("INC"),
            Event("INC"),
            Event("DEC"),
        ]
        let (replayed, matches) = replayStore(
            StoreConfig(context: ReplayCounterContext(count: 0), on: [
                "INC": { @Sendable ctx, _ in ctx.count += 1 },
                "DEC": { @Sendable ctx, _ in ctx.count -= 1 },
            ]),
            session: session,
            events: events
        )

        #expect(matches)
        #expect(replayed.context.count == 1)
    }

    @Test("pure store transitions replay")
    func storePureReplay() {
        let store = Store<ReplayCounterContext, Event>(
            StoreConfig(
                context: ReplayCounterContext(count: 0),
                on: ["INC": { @Sendable ctx, _ in ctx.count += 1 }]
            )
        )

        let initial = store.snapshot
        let results = replayStoreTransitions(
            store,
            from: initial,
            events: [Event("INC"), Event("INC")]
        )

        #expect(results.count == 3)
        #expect(results.last?.context.count == 2)
        #expect(store.context.count == 0)
    }
}