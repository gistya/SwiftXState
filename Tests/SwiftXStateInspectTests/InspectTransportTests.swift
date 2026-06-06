import Foundation
import Testing
@testable import SwiftXState
@testable import SwiftXStateInspect
@testable import SwiftXStateInspectURLSession

@Suite("Inspect transport and connectivity policy")
struct InspectTransportTests {
    @Test("localhostOnly permits loopback and rejects LAN/public hosts")
    func localhostPolicy() throws {
        let validator = EndpointValidator(policy: .localhostOnly())

        let local = try validator.validate(InspectEndpoint(host: "127.0.0.1", port: 9234))
        #expect(local.host == "127.0.0.1")

        #expect(throws: InspectTransportError.self) {
            try validator.validate(InspectEndpoint(host: "192.168.1.10", port: 9234))
        }
        #expect(throws: InspectTransportError.self) {
            try validator.validate(InspectEndpoint(host: "example.com", port: 9234))
        }
    }

    @Test("privateNetwork permits RFC1918 addresses")
    func privateNetworkPolicy() throws {
        let validator = EndpointValidator(policy: .privateNetwork())

        _ = try validator.validate(InspectEndpoint(host: "10.0.0.5", port: 9234))
        _ = try validator.validate(InspectEndpoint(host: "172.16.3.1", port: 9234))
        _ = try validator.validate(InspectEndpoint(host: "192.168.0.42", port: 9234))
        _ = try validator.validate(InspectEndpoint(host: "my-mac.local", port: 9234))

        #expect(throws: InspectTransportError.self) {
            try validator.validate(InspectEndpoint(host: "8.8.8.8", port: 9234))
        }
    }

    @Test("port policy restricts connections")
    func portPolicy() throws {
        let validator = EndpointValidator(policy: .localhostOnly(ports: .only([9234])))

        _ = try validator.validate(InspectEndpoint(host: "127.0.0.1", port: 9234))
        #expect(throws: InspectTransportError.self) {
            try validator.validate(InspectEndpoint(host: "127.0.0.1", port: 8080))
        }
    }

    @Test("environment defaults differ for simulator and device")
    func environmentDefaults() {
        let simulator = InspectRuntimeContext(hostKind: .iOSSimulator, isDebugBuild: true, isSimulator: true)
        let device = InspectRuntimeContext(hostKind: .iOSDevice, isDebugBuild: true, isSimulator: false)

        let simPolicy = InspectDefaults.recommendedPolicy(for: simulator)
        let devicePolicy = InspectDefaults.recommendedPolicy(for: device)

        if case .localhostOnly = simPolicy {
            #expect(Bool(true))
        } else {
            Issue.record("Simulator should default to localhostOnly")
        }

        if case .privateNetwork = devicePolicy {
            #expect(Bool(true))
        } else {
            Issue.record("Device should default to privateNetwork")
        }
    }

    @Test("enablement respects debug build and user opt-in")
    func enablement() {
        let release = InspectRuntimeContext(isDebugBuild: false)
        let enabled = InspectEnablement(requiresDebugBuild: true, userOptIn: true)
        #expect(enabled.isEnabled(in: release) == false)

        let debug = InspectRuntimeContext(isDebugBuild: true)
        #expect(enabled.isEnabled(in: debug) == true)

        let optedOut = InspectEnablement(requiresDebugBuild: false, userOptIn: false)
        #expect(optedOut.isEnabled(in: debug) == false)
    }

    @Test("mock transport records validated connections and messages")
    func mockTransport() async throws {
        let transport = MockInspectTransport(policy: .localhostOnly())
        let bridge = InspectBridge(
            transport: transport,
            configuration: InspectClientConfiguration(
                policy: .localhostOnly(),
                endpoint: InspectEndpoint(host: "127.0.0.1", port: 9234),
                runtime: InspectRuntimeContext(isDebugBuild: true),
                enablement: InspectEnablement(requiresDebugBuild: false, userOptIn: true),
                wireFormat: .envelope
            )
        )
        bridge.start()

        let event = InspectionEvent.actor(
            rootId: "root",
            actor: InspectionActorRef(sessionId: "root", machineId: "app")
        )
        bridge.observe()(event)

        await waitUntil { await transport.recordedMessages().count >= 1 }

        let endpoints = await transport.recordedEndpoints()
        let messages = await transport.recordedMessages()
        #expect(endpoints.count == 1)
        #expect(endpoints.first?.host == "127.0.0.1")
        #expect(messages.count == 1)
        #expect(messages.first?.type == "inspection.event")

        await bridge.stop()
    }

    @Test("mock transport rejects policy violations")
    func mockRejectsPublicHost() async {
        let transport = MockInspectTransport(policy: .localhostOnly())

        do {
            _ = try await transport.validatedConnect(
                to: InspectEndpoint(host: "192.168.1.1", port: 9234)
            )
            Issue.record("Expected policy violation")
        } catch let error as InspectTransportError {
            if case let .policyViolation(host, _) = error {
                #expect(host == "192.168.1.1")
            } else {
                Issue.record("Wrong error: \(error)")
            }
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("URLSession transport validates before connecting")
    func urlSessionPolicyGuard() async {
        #if SWIFTXSTATE_URL_SESSION_WEBSOCKET
        let transport = URLSessionInspectTransport(
            policy: .localhostOnly(),
            session: .shared
        )
        #else
        let transport = URLSessionInspectTransport(policy: .localhostOnly())
        #endif

        do {
            _ = try await transport.validatedConnect(
                to: InspectEndpoint(host: "example.com", port: 9234)
            )
            Issue.record("Expected policy violation")
        } catch let error as InspectTransportError {
            if case .policyViolation = error {
                #expect(Bool(true))
            } else {
                Issue.record("Wrong error: \(error)")
            }
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("inspect wire event round-trips to JSON")
    func wireEncoding() throws {
        let source = InspectionEvent.transition(
            rootId: "root",
            actor: InspectionActorRef(sessionId: "root", machineId: "app"),
            triggeringEvent: Event("GO"),
            machineSnapshot: MachineSnapshot(
                machine: createMachine(MachineConfig(
                    initial: "done",
                    context: EmptyContext(),
                    states: ["done": StateNodeConfig()]
                )),
                value: .atomic("done"),
                context: EmptyContext(),
                nodes: [],
                tags: [],
                status: .active
            )
        )

        let wire = InspectWireEvent(from: source)
        let data = try JSONEncoder().encode(wire)
        let decoded = try JSONDecoder().decode(InspectWireEvent.self, from: data)

        #expect(decoded.kind == "@xstate.transition")
        #expect(decoded.event?.type == "GO")
        #expect(decoded.snapshot?.value == "done")
    }
}