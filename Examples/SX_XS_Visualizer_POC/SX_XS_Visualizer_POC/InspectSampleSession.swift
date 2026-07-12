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
    /// Called on the main actor whenever the runtime's mirrored state changes (e.g. after the
    /// actor confirms an event), so the owning session can re-publish into its `@Observable` props.
    /// Needed because `Actor.send` is async: a button's `action()` returns before the snapshot
    /// updates, so the view can't rely on a synchronous refresh right after the tap.
    var onUpdate: (@MainActor () -> Void)? { get set }
    func start() async
    func stop() async
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
        inspectorEndpoint = endpoint.urlString
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
            await runtime.stop()
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
        newRuntime.onUpdate = { [weak self] in self?.syncFromRuntime() }
        await newRuntime.start()
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
) async throws -> (InspectBridge, @Sendable (InspectionEvent) -> Void) {
    let configuration = InspectClientConfiguration(
        policy: .localhostOnly(ports: .only([endpoint.port])),
        endpoint: endpoint,
        runtime: InspectRuntimeContext(isDebugBuild: true),
        enablement: InspectEnablement(requiresDebugBuild: false, userOptIn: true),
        wireFormat: .stately,
        machineDefinitions: [try InspectMachineRegistration(machine)]
    )
    let bridge = InspectBridge(transport: transport, configuration: configuration)
    await bridge.start()
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
    var onUpdate: (@MainActor () -> Void)?
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

    func start() async {
        do {
            let (bridge, inspect) = try await makeInspectBridge(machine: machine, transport: transport, endpoint: endpoint)
            self.bridge = bridge
            let actor = createActor(machine, inspect: inspect)
            self.actor = actor
            _ = await actor.subscribe { [weak self] snapshot in
                Task { @MainActor in self?.apply(snapshot) }
            }
            await actor.start()
            apply(await actor.snapshot)
        } catch {
            stateLine = "Inspect error"
            contextLine = String(describing: error)
            onUpdate?()
        }
    }

    func stop() async {
        await actor?.stop()
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
                Task { @MainActor in await self?.actor?.send(Event("toggle")) }
            },
        ]
        onUpdate?()
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
    var onUpdate: (@MainActor () -> Void)?
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

    func start() async {
        do {
            let (bridge, inspect) = try await makeInspectBridge(machine: machine, transport: transport, endpoint: endpoint)
            self.bridge = bridge
            let actor = createActor(machine, inspect: inspect)
            self.actor = actor
            _ = await actor.subscribe { [weak self] snapshot in
                Task { @MainActor in self?.apply(snapshot) }
            }
            await actor.start()
            apply(await actor.snapshot)
        } catch {
            stateLine = "Inspect error"
            contextLine = String(describing: error)
            onUpdate?()
        }
    }

    func stop() async {
        await actor?.stop()
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
                Task { @MainActor in await self?.actor?.send(Event("increase")) }
            },
        ]
        onUpdate?()
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
    var onUpdate: (@MainActor () -> Void)?
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

    func start() async {
        do {
            let (bridge, inspect) = try await makeInspectBridge(machine: machine, transport: transport, endpoint: endpoint)
            self.bridge = bridge
            let actor = createActor(machine, inspect: inspect)
            self.actor = actor
            _ = await actor.subscribe { [weak self] snapshot in
                Task { @MainActor in self?.apply(snapshot) }
            }
            await actor.start()
            apply(await actor.snapshot)
        } catch {
            stateLine = "Inspect error"
            contextLine = String(describing: error)
            onUpdate?()
        }
    }

    func stop() async {
        await actor?.stop()
        actor = nil
    }

    func stopInspect() async {
        if let bridge {
            await bridge.stop()
        }
        bridge = nil
    }

    func sendDraft() {
        let value = draftFeedback
        Task { @MainActor in await self.actor?.send(FeedbackUpdateEvent(value: value)) }
    }

    private func apply(_ snapshot: MachineSnapshot<FeedbackContext>) {
        stateLine = snapshot.value.description
        contextLine = "feedback: \"\(snapshot.context.feedback)\""
        draftFeedback = snapshot.context.feedback

        eventButtons = [
            DemoEventButton(id: "good", label: "feedback.good") { [weak self] in
                Task { @MainActor in await self?.actor?.send(Event("feedback.good")) }
            },
            DemoEventButton(id: "bad", label: "feedback.bad") { [weak self] in
                Task { @MainActor in await self?.actor?.send(Event("feedback.bad")) }
            },
            DemoEventButton(id: "update", label: "feedback.update (demo)") { [weak self] in
                Task { @MainActor in await self?.actor?.send(FeedbackUpdateEvent(value: "Needs more examples")) }
            },
            DemoEventButton(id: "submit", label: "submit") { [weak self] in
                Task { @MainActor in await self?.actor?.send(Event("submit")) }
            },
            DemoEventButton(id: "back", label: "back") { [weak self] in
                Task { @MainActor in await self?.actor?.send(Event("back")) }
            },
            DemoEventButton(id: "close", label: "close") { [weak self] in
                Task { @MainActor in await self?.actor?.send(Event("close")) }
            },
            DemoEventButton(id: "restart", label: "restart") { [weak self] in
                Task { @MainActor in await self?.actor?.send(Event("restart")) }
            },
        ]
        onUpdate?()
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
    var onUpdate: (@MainActor () -> Void)?
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

    func start() async {
        do {
            let (bridge, inspect) = try await makeInspectBridge(machine: machine, transport: transport, endpoint: endpoint)
            self.bridge = bridge
            let actor = createActor(machine, inspect: inspect)
            self.actor = actor
            _ = await actor.subscribe { [weak self] snapshot in
                Task { @MainActor in self?.apply(snapshot) }
            }
            await actor.start()
            apply(await actor.snapshot)
        } catch {
            stateLine = "Inspect error"
            contextLine = String(describing: error)
            onUpdate?()
        }
    }

    func stop() async {
        await actor?.stop()
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
                Task { @MainActor in await self?.actor?.send(Event("TIMER")) }
            },
            DemoEventButton(id: "ped", label: "PED_COUNTDOWN") { [weak self] in
                Task { @MainActor in await self?.actor?.send(Event("PED_COUNTDOWN")) }
            },
            DemoEventButton(id: "outage", label: "POWER_OUTAGE") { [weak self] in
                Task { @MainActor in await self?.actor?.send(Event("POWER_OUTAGE")) }
            },
        ]
        onUpdate?()
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
    var onUpdate: (@MainActor () -> Void)?
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

    func start() async {
        await bootActor()
    }

    func stop() async {
        await actor?.stop()
        actor = nil
    }

    func stopInspect() async {
        if let bridge {
            await bridge.stop()
        }
        bridge = nil
    }

    private func bootActor() async {
        await actor?.stop()
        actor = nil
        do {
            let inspect: @Sendable (InspectionEvent) -> Void
            if let bridge {
                inspect = bridge.observe()
            } else {
                let (newBridge, newInspect) = try await makeInspectBridge(
                    machine: machine,
                    transport: transport,
                    endpoint: endpoint
                )
                bridge = newBridge
                inspect = newInspect
            }
            let actor = createActor(machine, inspect: inspect)
            self.actor = actor
            _ = await actor.subscribe { [weak self] snapshot in
                Task { @MainActor in self?.apply(snapshot) }
            }
            await actor.start()
            apply(await actor.snapshot)
        } catch {
            stateLine = "Inspect error"
            contextLine = String(describing: error)
            onUpdate?()
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
                Task { @MainActor in await self?.bootActor() }
            },
        ]

        if snapshot.status == .active {
            buttons.insert(
                DemoEventButton(id: "submit", label: "Submit Order") { [weak self] in
                    Task { @MainActor in await self?.actor?.send(Event("SUBMIT")) }
                },
                at: 0
            )
            buttons.insert(
                DemoEventButton(id: "declined", label: "Submit Declined Card") { [weak self] in
                    Task { @MainActor in await self?.actor?.send(Event("SUBMIT_DECLINED")) }
                },
                at: 1
            )
        }

        eventButtons = buttons
        onUpdate?()
    }
}
