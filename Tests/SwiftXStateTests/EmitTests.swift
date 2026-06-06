import Foundation
import Testing
@testable import SwiftXState

private struct EmitContext: Sendable, Equatable {
    var message: String
}

private final class EmittedEventCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [EmittedEvent] = []

    func append(_ event: EmittedEvent) {
        lock.lock()
        events.append(event)
        lock.unlock()
    }

    func recorded() -> [EmittedEvent] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }
}

@Suite("emit actions")
struct EmitTests {
    @Test("emit records xstate.emit in transition actions")
    func recordsActionType() {
        let machine = createMachine(MachineConfig(
            initial: "idle",
            context: EmitContext(message: ""),
            states: [
                "idle": StateNodeConfig(on: [
                    "GO": .single(TransitionConfig(actions: [emit("notification")])),
                ]),
            ]
        ))

        let (initial, _) = SwiftXState.initialTransition(machine)
        let (_, actions) = SwiftXState.transition(machine, snapshot: initial, event: Event("GO"))

        #expect(actions.contains { $0.type == "xstate.emit" })
    }

    @Test("actor.on receives statically emitted events")
    func staticEmit() {
        let machine = createMachine(MachineConfig(
            initial: "idle",
            context: EmitContext(message: ""),
            states: [
                "idle": StateNodeConfig(on: [
                    "GO": .single(TransitionConfig(actions: [
                        emit(EmittedEvent("notification", property: "message", value: SendableValue("Hello"))),
                    ])),
                ]),
            ]
        ))

        let collector = EmittedEventCollector()
        let actor = createActor(machine).start()
        _ = actor.on("notification") { collector.append($0) }

        actor.send(Event("GO"))

        let recorded = collector.recorded()
        #expect(recorded.count == 1)
        #expect(recorded[0].type == "notification")
        #expect(recorded[0].get("message", as: String.self) == "Hello")
    }

    @Test("actor.on wildcard receives all emitted events")
    func wildcardEmit() {
        let machine = createMachine(MachineConfig(
            initial: "idle",
            context: EmitContext(message: ""),
            states: [
                "idle": StateNodeConfig(on: [
                    "GO": .single(TransitionConfig(actions: [
                        emit("first"),
                        emit("second"),
                    ])),
                ]),
            ]
        ))

        let collector = EmittedEventCollector()
        let actor = createActor(machine).start()
        _ = actor.on("*") { collector.append($0) }

        actor.send(Event("GO"))

        #expect(collector.recorded().map(\.type) == ["first", "second"])
    }

    @Test("emit expression resolves from context")
    func dynamicEmit() {
        let machine = createMachine(MachineConfig(
            initial: "idle",
            context: EmitContext(message: "dynamic"),
            states: [
                "idle": StateNodeConfig(on: [
                    "GO": .single(TransitionConfig(actions: [
                        emit { args in
                            EmittedEvent(
                                "notification",
                                property: "message",
                                value: SendableValue(args.context.message)
                            )
                        },
                    ])),
                ]),
            ]
        ))

        let collector = EmittedEventCollector()
        let actor = createActor(machine).start()
        _ = actor.on("notification") { collector.append($0) }

        actor.send(Event("GO"))

        #expect(collector.recorded().first?.get("message", as: String.self) == "dynamic")
    }

    @Test("on subscription unsubscribe stops delivery")
    func unsubscribe() {
        let machine = createMachine(MachineConfig(
            initial: "idle",
            context: EmitContext(message: ""),
            states: [
                "idle": StateNodeConfig(on: [
                    "GO": .single(TransitionConfig(actions: [emit("ping")])),
                ]),
            ]
        ))

        let collector = EmittedEventCollector()
        let actor = createActor(machine).start()
        let subscription = actor.on("ping") { collector.append($0) }

        actor.send(Event("GO"))
        subscription.cancel()
        actor.send(Event("GO"))

        #expect(collector.recorded().count == 1)
    }

    @Test("fromTask scope emit delivers to child on()")
    func taskScopeEmit() async {
        let parentMachine = createMachine(MachineConfig(
            initial: "running",
            context: EmitContext(message: ""),
            states: [
                "running": StateNodeConfig(
                    invoke: [
                        InvokeConfig(
                            id: "worker",
                            src: fromTask { scope in
                                try await Task.sleep(for: .milliseconds(30))
                                scope.emit(
                                    EmittedEvent("progress", property: "step", value: SendableValue(1))
                                )
                                return "ok"
                            }
                        ),
                    ]
                ),
            ]
        ))

        let collector = EmittedEventCollector()
        let received = TestSignal()
        let actor = createActor(parentMachine).start()
        _ = actor.childActor(id: "worker")?.on("progress") {
            collector.append($0)
            received.fire()
        }

        await received.wait()

        #expect(collector.recorded().first?.get("step", as: Int.self) == 1)
    }

    @Test("fromCallback scope emit delivers to child on()")
    func callbackScopeEmit() async {
        let parentMachine = createMachine(MachineConfig(
            initial: "listening",
            context: EmitContext(message: ""),
            states: [
                "listening": StateNodeConfig(
                    invoke: [
                        InvokeConfig(
                            id: "listener",
                            src: fromCallback { scope in
                                scope.receive { event in
                                    if event.type == "ARM" {
                                        scope.emit(EmittedEvent("armed"))
                                    }
                                }
                                return nil
                            }
                        ),
                    ]
                ),
            ]
        ))

        let collector = EmittedEventCollector()
        let received = TestSignal()
        let actor = createActor(parentMachine).start()
        _ = actor.childActor(id: "listener")?.on("armed") {
            collector.append($0)
            received.fire()
        }

        actor.childActor(id: "listener")?.send(Event("ARM"))
        await received.wait()

        #expect(collector.recorded().map(\.type) == ["armed"])
    }

    @Test("fromTaskGroup scope emit delivers to child on()")
    func taskGroupScopeEmit() async {
        let parentMachine = createMachine(MachineConfig(
            initial: "running",
            context: EmitContext(message: ""),
            states: [
                "running": StateNodeConfig(
                    invoke: [
                        InvokeConfig(
                            id: "group",
                            src: fromTaskGroup { scope -> [Int] in
                                try await Task.sleep(for: .milliseconds(30))
                                scope.emit(
                                    EmittedEvent("progress", property: "count", value: SendableValue(2))
                                )
                                return try await scope.runGroup([
                                    { 1 },
                                    { 2 },
                                ])
                            }
                        ),
                    ]
                ),
            ]
        ))

        let collector = EmittedEventCollector()
        let received = TestSignal()
        let actor = createActor(parentMachine).start()
        _ = actor.childActor(id: "group")?.on("progress") {
            collector.append($0)
            received.fire()
        }

        await received.wait()

        #expect(collector.recorded().first?.get("count", as: Int.self) == 2)
    }

    @Test("emit emits inspection action events from actors")
    func inspectionAction() {
        let collector = InspectionCollector()
        let machine = createMachine(MachineConfig(
            initial: "idle",
            context: EmitContext(message: ""),
            states: [
                "idle": StateNodeConfig(on: [
                    "GO": .single(TransitionConfig(actions: [emit("trace")])),
                ]),
            ]
        ))

        createActor(machine, options: ActorOptions(inspect: collector.observe())).start().send(Event("GO"))

        #expect(collector.recordedEvents().contains { $0.kind == .action && $0.actionType == "xstate.emit" })
    }
}