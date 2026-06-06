import Foundation
import Testing
@testable import SwiftXState

private struct LogContext: Sendable, Equatable {
    var count: Int
}

private final class LogOutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var outputs: [LogOutput] = []

    func append(_ output: LogOutput) {
        lock.lock()
        outputs.append(output)
        lock.unlock()
    }

    func recorded() -> [LogOutput] {
        lock.lock()
        defer { lock.unlock() }
        return outputs
    }

    func clear() {
        lock.lock()
        outputs.removeAll()
        lock.unlock()
    }
}

@Suite("log actions", .serialized)
struct LogTests {
    private func runLog(
        _ ref: ActionRef<LogContext>,
        context: LogContext = LogContext(count: 0),
        event: any Eventable = Event("GO")
    ) -> (LogContext, [LogOutput]) {
        let collector = LogOutputCollector()
        LogHandler.setSink { collector.append($0) }
        defer { LogHandler.setSink(nil) }

        var context = context
        let action = ExecutableAction(ref: ref)
        let args = ActionArgs(context: context, event: event)
        executeAction(
            action,
            context: &context,
            args: args,
            implementations: MachineImplementations()
        )
        return (context, collector.recorded())
    }

    @Test("log records xstate.log in transition actions")
    func recordsActionType() {
        let machine = createMachine(MachineConfig(
            initial: "idle",
            context: LogContext(count: 0),
            states: [
                "idle": StateNodeConfig(on: [
                    "GO": .single(TransitionConfig(actions: [log("hello")])),
                ]),
            ]
        ))

        let (initial, _) = SwiftXState.initialTransition(machine)
        let (_, actions) = SwiftXState.transition(machine, snapshot: initial, event: Event("GO"))

        #expect(actions.contains { $0.type == "xstate.log" })
    }

    @Test("log emits a fixed message")
    func fixedMessage() {
        let (_, outputs) = runLog(log("armed"))

        #expect(outputs.count == 1)
        #expect(outputs[0].label == nil)
        #expect(outputs[0].message == "armed")
    }

    @Test("log evaluates expressions and supports labels")
    func expressionWithLabel() {
        let (_, outputs) = runLog(
            log({ args in SendableValue(args.context.count) }, label: "count"),
            context: LogContext(count: 3)
        )

        #expect(outputs.count == 1)
        #expect(outputs[0].label == "count")
        #expect(outputs[0].message == "3")
    }

    @Test("log defaults to context and event")
    func contextAndEvent() {
        let (_, outputs) = runLog(
            log(),
            context: LogContext(count: 7),
            event: SystemEvent.`init`
        )

        #expect(outputs.count == 1)
        #expect(outputs[0].message.contains("7"))
        #expect(outputs[0].message.contains("xstate.init"))
    }

    @Test("log emits inspection action events from actors")
    func inspectionAction() {
        let collector = InspectionCollector()
        let machine = createMachine(MachineConfig(
            initial: "idle",
            context: LogContext(count: 0),
            states: [
                "idle": StateNodeConfig(on: [
                    "GO": .single(TransitionConfig(actions: [log("trace")])),
                ]),
            ]
        ))

        LogHandler.setSink { _ in }
        defer { LogHandler.setSink(nil) }

        createActor(machine, options: ActorOptions(inspect: collector.observe())).start().send(Event("GO"))

        #expect(collector.recordedEvents().contains { $0.kind == .action && $0.actionType == "xstate.log" })
    }
}