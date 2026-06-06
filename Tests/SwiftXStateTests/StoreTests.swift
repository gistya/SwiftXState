import Foundation
import Testing
@testable import SwiftXState

struct StoreContext: Sendable, Equatable {
    var count: Int
    var name: String
}

enum StoreEvent: Eventable, Equatable {
    case increment
    case incrementBy(Int)
    case setName(String)
    case incTwice

    var type: String {
        switch self {
        case .increment: return "increment"
        case .incrementBy: return "incrementBy"
        case .setName: return "setName"
        case .incTwice: return "incTwice"
        }
    }
}

private let storeIncrement: StoreMutator<StoreContext, StoreEvent> = { @Sendable ctx, _ in
    ctx.count += 1
}

@Suite("Store")
struct StoreTests {
    @Test("send updates context")
    func sendUpdates() {
        let store = Store<StoreContext, StoreEvent>(
            StoreConfig(
                context: StoreContext(count: 0, name: "test"),
                on: [
                    "increment": { @Sendable ctx, _ in ctx.count += 1 },
                    "setName": { @Sendable ctx, event in
                        if case let .setName(name) = event {
                            ctx.name = name
                        }
                    },
                ]
            )
        )

        store.send(StoreEvent.increment)
        #expect(store.context.count == 1)

        store.send(StoreEvent.setName("updated"))
        #expect(store.context.name == "updated")
    }

    @Test("transition without mutation")
    func pureTransition() {
        let store = Store<StoreContext, StoreEvent>(
            StoreConfig(
                context: StoreContext(count: 0, name: "test"),
                on: ["increment": { @Sendable ctx, _ in ctx.count += 1 }]
            )
        )

        let current = store.snapshot
        let next = store.transition(current, event: StoreEvent.increment)

        #expect(current.context.count == 0)
        #expect(next.context.count == 1)
        #expect(store.context.count == 0)
    }

    @Test("subscribe receives updates")
    func subscribe() {
        let store = Store<StoreContext, StoreEvent>(
            StoreConfig(
                context: StoreContext(count: 0, name: "test"),
                on: ["increment": { @Sendable ctx, _ in ctx.count += 1 }]
            )
        )

        var received: [Int] = []
        let sub = store.subscribe { snap in
            received.append(snap.context.count)
        }

        store.send(StoreEvent.increment)
        store.send(StoreEvent.increment)
        sub.cancel()

        #expect(received == [0, 1, 2])
    }

    @Test("assigner can reject events")
    func canRejects() {
        let store = Store(
            StoreConfig(
                context: StoreContext(count: 0, name: "test"),
                assign: [
                    "incrementBy": { @Sendable (context: StoreContext, event: StoreEvent, _: StoreEnqueue<StoreContext, StoreEvent>) in
                    guard case let .incrementBy(by) = event else { return context }
                    if context.count + by > 10 {
                        return nil
                    }
                    return StoreContext(count: context.count + by, name: context.name)
                    },
                ]
            )
        )

        #expect(store.can(StoreEvent.incrementBy(4)) == true)
        #expect(store.can(StoreEvent.incrementBy(11)) == false)

        store.send(StoreEvent.incrementBy(4))
        #expect(store.context.count == 4)

        store.send(StoreEvent.incrementBy(11))
        #expect(store.context.count == 4)
    }

    @Test("enqueue emit and trigger")
    func enqueueEffects() {
        let emitted = StoreEmittedCapture()
        let effectRan = StoreFlag()

        let store = Store(
            StoreConfig(
                context: StoreContext(count: 0, name: "test"),
                assign: [
                    "increment": { @Sendable (context: StoreContext, _: StoreEvent, enqueue: StoreEnqueue<StoreContext, StoreEvent>) in
                        enqueue.emit(EmittedEvent("increased", property: "by", value: SendableValue(1)))
                        enqueue.effect { effectRan.value = true }
                        return StoreContext(count: context.count + 1, name: context.name)
                    },
                    "incTwice": { @Sendable (context: StoreContext, _: StoreEvent, enqueue: StoreEnqueue<StoreContext, StoreEvent>) in
                        enqueue.trigger(StoreEvent.increment)
                        enqueue.trigger(StoreEvent.increment)
                        return context
                    },
                ]
            )
        )

        _ = store.on("increased") { event in
            emitted.append(event.type)
        }

        store.send(StoreEvent.incTwice)

        #expect(store.context.count == 2)
        #expect(emitted.values == ["increased", "increased"])
        #expect(effectRan.value == true)
    }

    @Test("transitionResult returns effects without mutating store")
    func transitionResult() {
        let store = Store(
            StoreConfig(
                context: StoreContext(count: 0, name: "test"),
                assign: [
                    "increment": { @Sendable (context: StoreContext, _: StoreEvent, enqueue: StoreEnqueue<StoreContext, StoreEvent>) in
                        enqueue.emit(EmittedEvent("increased"))
                        return StoreContext(count: context.count + 1, name: context.name)
                    },
                ]
            )
        )

        let result = store.transitionResult(store.getInitialSnapshot(), event: StoreEvent.increment)

        #expect(result.snapshot.context.count == 1)
        #expect(result.effects.count == 1)
        #expect(store.context.count == 0)
    }

    @Test("selector subscribes to derived slice")
    func selectorSubscribe() {
        let store = Store(
            StoreConfig(
                context: StoreContext(count: 0, name: "test"),
                on: [
                    "increment": storeIncrement,
                    "setName": { @Sendable ctx, event in
                        if case let .setName(name) = event {
                            ctx.name = name
                        }
                    },
                ]
            )
        )

        let count = store.select { $0.count }
        var received: [Int] = []
        _ = count.subscribe { received.append($0) }

        store.send(StoreEvent.increment)
        store.send(StoreEvent.setName("changed"))

        #expect(received == [0, 1])
    }

    @Test("getInitialSnapshot preserves starting state")
    func initialSnapshot() {
        let store = Store(
            StoreConfig(
                context: StoreContext(count: 5, name: "initial"),
                on: ["increment": storeIncrement]
            )
        )
        store.send(StoreEvent.increment)

        #expect(store.getInitialSnapshot().context.count == 5)
        #expect(store.getSnapshot().context.count == 6)
    }

    @Test("stop ignores further events")
    func stop() {
        let store = Store(
            StoreConfig(
                context: StoreContext(count: 0, name: "test"),
                on: ["increment": storeIncrement]
            )
        )

        store.stop()
        store.send(StoreEvent.increment)

        #expect(store.getSnapshot().status == .stopped)
        #expect(store.context.count == 0)
    }

    @Test("inspect receives snapshot and transitions")
    func inspect() {
        let store = Store(
            StoreConfig(
                context: StoreContext(count: 0, name: "test"),
                on: ["increment": storeIncrement]
            )
        )

        var kinds: [InspectionEventKind] = []
        let sub = store.inspect { event in
            kinds.append(event.kind)
        }

        store.send(StoreEvent.increment)
        sub.cancel()

        #expect(kinds == [.snapshot, .transition])
    }

    @Test("createStoreLogic with input")
    func storeLogic() {
        let logic = StoreLogic<StoreContext, StoreEvent>(
            resolveConfig: { input in
                StoreConfig(
                    context: StoreContext(count: input?.get(Int.self) ?? 0, name: "logic"),
                    on: ["increment": storeIncrement]
                )
            }
        )

        let store = logic.createStore(input: SendableValue(3))
        store.send(StoreEvent.increment)

        #expect(store.context.count == 4)
    }

    @Test("fromStore spawns store child actor")
    func fromStoreActor() {
        let storeSource = fromStore(
            context: StoreContext(count: 0, name: "child"),
            on: ["increment": storeIncrement]
        )

        let parentMachine: StateMachine<EmptyContext> = createMachine(MachineConfig<EmptyContext>(
            initial: "idle",
            context: EmptyContext(),
            states: [
                "idle": StateNodeConfig(
                    on: [
                        "GO": .single(TransitionConfig(target: "done")),
                    ],
                    entry: [
                        .spawn(SpawnRef(
                            src: storeSource,
                            id: "counter",
                            input: { _ in SendableValue(2) },
                            syncSnapshot: true
                        )),
                    ]
                ),
                "done": StateNodeConfig(type: .final),
            ]
        ))

        let actor = createActor(parentMachine).start()

        #expect(actor.snapshot.children["counter"] != nil)
        #expect(actor.snapshot.children["counter"]?.status == .active)

        actor.send(Event("GO"))
        #expect(actor.snapshot.value == StateValue.atomic("done"))
    }
}

private final class StoreFlag: @unchecked Sendable {
    var value = false
}

private final class StoreEmittedCapture: @unchecked Sendable {
    private var lock = NSLock()
    private(set) var values: [String] = []

    func append(_ value: String) {
        lock.lock()
        values.append(value)
        lock.unlock()
    }
}