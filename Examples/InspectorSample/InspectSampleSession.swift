import Foundation
import SwiftXState
import SwiftXStateInspect
import SwiftXStateInspectURLSession

struct DemoEventButton: Identifiable, Sendable {
    let id: String
    let label: String
    let action: @MainActor @Sendable () -> Void
}

@MainActor
protocol DemoRuntime: AnyObject {
    var demo: SampleDemoID { get }
    var stateLine: String { get }
    var contextLine: String { get }
    var eventButtons: [DemoEventButton] { get }
    func start()
    func stop()
    func stopInspect() async
}

@MainActor
@Observable
final class InspectSampleSession {
    var selectedDemo: SampleDemoID = .toggle {
        didSet { Task { await switchDemo(to: selectedDemo) } }
    }

    var connectionStatus: String = "Idle"
    var stateLine: String = "—"
    var contextLine: String = "—"
    var eventButtons: [DemoEventButton] = []
    var inspectorEndpoint: String

    private let transport: URLSessionInspectTransport
    private let endpoint: InspectEndpoint
    private var runtime: (any DemoRuntime)?

    init(
        host: String = "127.0.0.1",
        port: Int = 8080
    ) {
        endpoint = InspectEndpoint(host: host, port: port)
        inspectorEndpoint = endpoint.url?.absoluteString ?? "ws://\(host):\(port)"
        transport = URLSessionInspect.transport(
            policy: .localhostOnly(ports: .only([port])),
            runtime: InspectRuntimeContext(isDebugBuild: true)
        )
        Task { await switchDemo(to: selectedDemo) }
    }

    func refresh() {
        syncFromRuntime()
    }

    private func switchDemo(to demo: SampleDemoID) async {
        if let runtime {
            runtime.stop()
            await runtime.stopInspect()
        }
        connectionStatus = "Connecting…"

        let newRuntime: any DemoRuntime
        switch demo {
        case .toggle:
            newRuntime = ToggleRuntime(machine: ToggleMachineFactory.make(), transport: transport, endpoint: endpoint)
        case .counter:
            newRuntime = CounterRuntime(machine: CounterMachineFactory.make(), transport: transport, endpoint: endpoint)
        case .feedback:
            newRuntime = FeedbackRuntime(machine: FeedbackMachineFactory.make(), transport: transport, endpoint: endpoint)
        case .trafficLight:
            newRuntime = TrafficLightRuntime(
                machine: TrafficLightMachineFactory.make(),
                transport: transport,
                endpoint: endpoint
            )
        case .checkout:
            newRuntime = CheckoutRuntime(
                machine: CheckoutMachineFactory.make(),
                transport: transport,
                endpoint: endpoint
            )
        }

        runtime = newRuntime
        newRuntime.start()
        connectionStatus = "Connected → Stately Inspector"
        syncFromRuntime()
    }

    private func syncFromRuntime() {
        guard let runtime else { return }
        stateLine = runtime.stateLine
        contextLine = runtime.contextLine
        eventButtons = runtime.eventButtons
    }
}

// MARK: - Shared runtime helper

@MainActor
private func makeInspectBridge<Context: Sendable>(
    machine: StateMachine<Context>,
    transport: URLSessionInspectTransport,
    endpoint: InspectEndpoint
) throws -> (InspectBridge, @Sendable (InspectionEvent) -> Void) {
    let configuration = InspectClientConfiguration(
        policy: .localhostOnly(ports: .only([endpoint.port])),
        endpoint: endpoint,
        runtime: InspectRuntimeContext(isDebugBuild: true),
        enablement: InspectEnablement(requiresDebugBuild: false, userOptIn: true),
        wireFormat: .stately,
        machineDefinitions: [try InspectMachineRegistration(machine)]
    )
    let bridge = InspectBridge(transport: transport, configuration: configuration)
    bridge.start()
    return (bridge, bridge.observe())
}

@MainActor
private final class ToggleRuntime: DemoRuntime {
    let demo: SampleDemoID = .toggle
    private let machine: StateMachine<EmptyContext>
    private let transport: URLSessionInspectTransport
    private let endpoint: InspectEndpoint
    private var actor: Actor<EmptyContext>?
    private var bridge: InspectBridge?
    private(set) var stateLine = "inactive"
    private(set) var contextLine = "—"
    private(set) var eventButtons: [DemoEventButton] = []

    init(
        machine: StateMachine<EmptyContext>,
        transport: URLSessionInspectTransport,
        endpoint: InspectEndpoint
    ) {
        self.machine = machine
        self.transport = transport
        self.endpoint = endpoint
    }

    func start() {
        do {
            let (bridge, inspect) = try makeInspectBridge(machine: machine, transport: transport, endpoint: endpoint)
            self.bridge = bridge
            let actor = createActor(machine, inspect: inspect)
            self.actor = actor
            _ = actor.subscribe { [weak self] snapshot in
                Task { @MainActor in self?.apply(snapshot) }
            }
            actor.start()
            apply(actor.snapshot)
        } catch {
            stateLine = "Inspect error"
            contextLine = String(describing: error)
        }
    }

    func stop() {
        actor?.stop()
        actor = nil
    }

    func stopInspect() async {
        if let bridge {
            await bridge.stop()
        }
        bridge = nil
    }

    private func apply(_ snapshot: MachineSnapshot<EmptyContext>) {
        stateLine = snapshot.value.description
        eventButtons = [
            DemoEventButton(id: "toggle", label: "toggle") { [weak self] in
                self?.actor?.send(Event("toggle"))
                if let snapshot = self?.actor?.snapshot { self?.apply(snapshot) }
            },
        ]
    }
}

@MainActor
private final class CounterRuntime: DemoRuntime {
    let demo: SampleDemoID = .counter
    private let machine: StateMachine<CounterContext>
    private let transport: URLSessionInspectTransport
    private let endpoint: InspectEndpoint
    private var actor: Actor<CounterContext>?
    private var bridge: InspectBridge?
    private(set) var stateLine = "ready"
    private(set) var contextLine = "count: 0"
    private(set) var eventButtons: [DemoEventButton] = []

    init(
        machine: StateMachine<CounterContext>,
        transport: URLSessionInspectTransport,
        endpoint: InspectEndpoint
    ) {
        self.machine = machine
        self.transport = transport
        self.endpoint = endpoint
    }

    func start() {
        do {
            let (bridge, inspect) = try makeInspectBridge(machine: machine, transport: transport, endpoint: endpoint)
            self.bridge = bridge
            let actor = createActor(machine, inspect: inspect)
            self.actor = actor
            _ = actor.subscribe { [weak self] snapshot in
                Task { @MainActor in self?.apply(snapshot) }
            }
            actor.start()
            apply(actor.snapshot)
        } catch {
            stateLine = "Inspect error"
            contextLine = String(describing: error)
        }
    }

    func stop() {
        actor?.stop()
        actor = nil
    }

    func stopInspect() async {
        if let bridge {
            await bridge.stop()
        }
        bridge = nil
    }

    private func apply(_ snapshot: MachineSnapshot<CounterContext>) {
        stateLine = snapshot.value.description
        contextLine = "count: \(snapshot.context.count)"
        eventButtons = [
            DemoEventButton(id: "increase", label: "increase") { [weak self] in
                self?.actor?.send(Event("increase"))
                if let snapshot = self?.actor?.snapshot { self?.apply(snapshot) }
            },
        ]
    }
}

@MainActor
private final class FeedbackRuntime: DemoRuntime {
    let demo: SampleDemoID = .feedback
    private let machine: StateMachine<FeedbackContext>
    private let transport: URLSessionInspectTransport
    private let endpoint: InspectEndpoint
    private var actor: Actor<FeedbackContext>?
    private var bridge: InspectBridge?
    private var draftFeedback = ""
    private(set) var stateLine = "prompt"
    private(set) var contextLine = "feedback: \"\""
    private(set) var eventButtons: [DemoEventButton] = []

    init(
        machine: StateMachine<FeedbackContext>,
        transport: URLSessionInspectTransport,
        endpoint: InspectEndpoint
    ) {
        self.machine = machine
        self.transport = transport
        self.endpoint = endpoint
    }

    func start() {
        do {
            let (bridge, inspect) = try makeInspectBridge(machine: machine, transport: transport, endpoint: endpoint)
            self.bridge = bridge
            let actor = createActor(machine, inspect: inspect)
            self.actor = actor
            _ = actor.subscribe { [weak self] snapshot in
                Task { @MainActor in self?.apply(snapshot) }
            }
            actor.start()
            apply(actor.snapshot)
        } catch {
            stateLine = "Inspect error"
            contextLine = String(describing: error)
        }
    }

    func stop() {
        actor?.stop()
        actor = nil
    }

    func stopInspect() async {
        if let bridge {
            await bridge.stop()
        }
        bridge = nil
    }

    func sendDraft() {
        actor?.send(FeedbackUpdateEvent(value: draftFeedback))
        if let snapshot = actor?.snapshot { apply(snapshot) }
    }

    private func apply(_ snapshot: MachineSnapshot<FeedbackContext>) {
        stateLine = snapshot.value.description
        contextLine = "feedback: \"\(snapshot.context.feedback)\""
        draftFeedback = snapshot.context.feedback

        eventButtons = [
            DemoEventButton(id: "good", label: "feedback.good") { [weak self] in
                self?.actor?.send(Event("feedback.good"))
                if let snapshot = self?.actor?.snapshot { self?.apply(snapshot) }
            },
            DemoEventButton(id: "bad", label: "feedback.bad") { [weak self] in
                self?.actor?.send(Event("feedback.bad"))
                if let snapshot = self?.actor?.snapshot { self?.apply(snapshot) }
            },
            DemoEventButton(id: "update", label: "feedback.update (demo)") { [weak self] in
                self?.actor?.send(FeedbackUpdateEvent(value: "Needs more examples"))
                if let snapshot = self?.actor?.snapshot { self?.apply(snapshot) }
            },
            DemoEventButton(id: "submit", label: "submit") { [weak self] in
                self?.actor?.send(Event("submit"))
                if let snapshot = self?.actor?.snapshot { self?.apply(snapshot) }
            },
            DemoEventButton(id: "back", label: "back") { [weak self] in
                self?.actor?.send(Event("back"))
                if let snapshot = self?.actor?.snapshot { self?.apply(snapshot) }
            },
            DemoEventButton(id: "close", label: "close") { [weak self] in
                self?.actor?.send(Event("close"))
                if let snapshot = self?.actor?.snapshot { self?.apply(snapshot) }
            },
            DemoEventButton(id: "restart", label: "restart") { [weak self] in
                self?.actor?.send(Event("restart"))
                if let snapshot = self?.actor?.snapshot { self?.apply(snapshot) }
            },
        ]
    }
}

@MainActor
private final class TrafficLightRuntime: DemoRuntime {
    let demo: SampleDemoID = .trafficLight
    private let machine: StateMachine<EmptyContext>
    private let transport: URLSessionInspectTransport
    private let endpoint: InspectEndpoint
    private var actor: Actor<EmptyContext>?
    private var bridge: InspectBridge?
    private(set) var stateLine = "green"
    private(set) var contextLine = "Nested pedestrian states under red"
    private(set) var eventButtons: [DemoEventButton] = []

    init(
        machine: StateMachine<EmptyContext>,
        transport: URLSessionInspectTransport,
        endpoint: InspectEndpoint
    ) {
        self.machine = machine
        self.transport = transport
        self.endpoint = endpoint
    }

    func start() {
        do {
            let (bridge, inspect) = try makeInspectBridge(machine: machine, transport: transport, endpoint: endpoint)
            self.bridge = bridge
            let actor = createActor(machine, inspect: inspect)
            self.actor = actor
            _ = actor.subscribe { [weak self] snapshot in
                Task { @MainActor in self?.apply(snapshot) }
            }
            actor.start()
            apply(actor.snapshot)
        } catch {
            stateLine = "Inspect error"
            contextLine = String(describing: error)
        }
    }

    func stop() {
        actor?.stop()
        actor = nil
    }

    func stopInspect() async {
        if let bridge {
            await bridge.stop()
        }
        bridge = nil
    }

    private func apply(_ snapshot: MachineSnapshot<EmptyContext>) {
        stateLine = snapshot.value.description
        eventButtons = [
            DemoEventButton(id: "timer", label: "TIMER") { [weak self] in
                self?.actor?.send(Event("TIMER"))
                if let snapshot = self?.actor?.snapshot { self?.apply(snapshot) }
            },
            DemoEventButton(id: "ped", label: "PED_COUNTDOWN") { [weak self] in
                self?.actor?.send(Event("PED_COUNTDOWN"))
                if let snapshot = self?.actor?.snapshot { self?.apply(snapshot) }
            },
            DemoEventButton(id: "outage", label: "POWER_OUTAGE") { [weak self] in
                self?.actor?.send(Event("POWER_OUTAGE"))
                if let snapshot = self?.actor?.snapshot { self?.apply(snapshot) }
            },
        ]
    }
}

@MainActor
private final class CheckoutRuntime: DemoRuntime {
    let demo: SampleDemoID = .checkout
    private let machine: StateMachine<CheckoutContext>
    private let transport: URLSessionInspectTransport
    private let endpoint: InspectEndpoint
    private var actor: Actor<CheckoutContext>?
    private var bridge: InspectBridge?
    private(set) var stateLine = "idle"
    private(set) var contextLine = "order ORD-1001 · $149.99"
    private(set) var eventButtons: [DemoEventButton] = []

    init(
        machine: StateMachine<CheckoutContext>,
        transport: URLSessionInspectTransport,
        endpoint: InspectEndpoint
    ) {
        self.machine = machine
        self.transport = transport
        self.endpoint = endpoint
    }

    func start() {
        bootActor()
    }

    func stop() {
        actor?.stop()
        actor = nil
    }

    func stopInspect() async {
        if let bridge {
            await bridge.stop()
        }
        bridge = nil
    }

    private func bootActor() {
        actor?.stop()
        actor = nil
        do {
            let inspect: @Sendable (InspectionEvent) -> Void
            if let bridge {
                inspect = bridge.observe()
            } else {
                let (newBridge, newInspect) = try makeInspectBridge(
                    machine: machine,
                    transport: transport,
                    endpoint: endpoint
                )
                bridge = newBridge
                inspect = newInspect
            }
            let actor = createActor(machine, inspect: inspect)
            self.actor = actor
            _ = actor.subscribe { [weak self] snapshot in
                Task { @MainActor in self?.apply(snapshot) }
            }
            actor.start()
            apply(actor.snapshot)
        } catch {
            stateLine = "Inspect error"
            contextLine = String(describing: error)
        }
    }

    private func apply(_ snapshot: MachineSnapshot<CheckoutContext>) {
        stateLine = "\(snapshot.value.description) · \(snapshot.status)"
        var lines = [
            "order: \(snapshot.context.orderId)",
            "amount: \(snapshot.context.amount)",
            "cardValid: \(snapshot.context.cardValid)",
        ]
        if let transactionId = snapshot.context.transactionId {
            lines.append("transactionId: \(transactionId)")
        }
        if let output = snapshot.output?.get(CheckoutResult.self) {
            lines.append("output.status: \(output.status)")
            lines.append("output.transactionId: \(output.transactionId)")
        }
        if let error = snapshot.error?.get(String.self) {
            lines.append("error: \(error)")
        }
        contextLine = lines.joined(separator: "\n")

        var buttons: [DemoEventButton] = [
            DemoEventButton(id: "restart", label: "Restart") { [weak self] in
                self?.bootActor()
            },
        ]

        if snapshot.status == .active {
            buttons.insert(
                DemoEventButton(id: "submit", label: "Submit Order") { [weak self] in
                    self?.actor?.send(Event("SUBMIT"))
                    if let snapshot = self?.actor?.snapshot { self?.apply(snapshot) }
                },
                at: 0
            )
            buttons.insert(
                DemoEventButton(id: "declined", label: "Submit Declined Card") { [weak self] in
                    self?.actor?.send(Event("SUBMIT_DECLINED"))
                    if let snapshot = self?.actor?.snapshot { self?.apply(snapshot) }
                },
                at: 1
            )
        }

        eventButtons = buttons
    }
}