import Foundation
import Testing
@testable import SwiftXState
@testable import SwiftXStateInspect

@Suite("Context publishing policies (Diff Mode)")
struct ContextPublishingTests {
    private func snapshotEvent(sessionId: String = "a", context: JSONValue) -> InspectionEvent {
        let actor = InspectionActorRef(sessionId: sessionId)
        return InspectionEvent(
            kind: .snapshot,
            rootId: sessionId,
            actor: actor,
            event: InspectionEventDescription(type: "TICK"),
            snapshot: InspectionSnapshot(
                actor: actor,
                status: .active,
                value: "running",
                stateValue: .atomic("running"),
                tags: [],
                childCount: 0,
                context: context
            )
        )
    }

    private func bridge(
        _ policy: InspectContextPublishing,
        transport: MockInspectTransport
    ) -> InspectBridge {
        InspectBridge(
            transport: transport,
            configuration: InspectClientConfiguration(
                policy: .localhostOnly(),
                endpoint: InspectEndpoint(host: "127.0.0.1", port: 8080),
                enablement: InspectEnablement(requiresDebugBuild: false, userOptIn: true),
                wireFormat: .envelope,
                contextPublishing: policy
            )
        )
    }

    /// Decodes the published envelopes back into wire events.
    private func publishedSnapshots(_ transport: MockInspectTransport) async throws -> [InspectWireSnapshot] {
        let messages = await transport.recordedMessages()
        return try messages.compactMap { message -> InspectWireSnapshot? in
            try JSONDecoder().decode(InspectWireEvent.self, from: Data(message.payload)).snapshot
        }
    }

    private func publish(_ events: [InspectionEvent], through bridge: InspectBridge, into transport: MockInspectTransport) async {
        await bridge.start()
        let observe = bridge.observe()
        for event in events { observe(event) }
        await waitUntil { await transport.recordedMessages().count >= events.count }
        await bridge.stop()
    }

    @Test("diff mode sends a full keyframe first, then only the change")
    func diffSendsKeyframeThenDeltas() async throws {
        let transport = MockInspectTransport(policy: .localhostOnly())
        let bridge = bridge(.diff(keyframeEvery: 0), transport: transport)

        await publish([
            snapshotEvent(context: .object(["count": .number(1), "name": .string("stable")])),
            snapshotEvent(context: .object(["count": .number(2), "name": .string("stable")])),
        ], through: bridge, into: transport)

        let snapshots = try await publishedSnapshots(transport)
        #expect(snapshots.count == 2)

        // First is the keyframe: full context, no delta.
        #expect(snapshots[0].contextDelta == nil)
        #expect(snapshots[0].context == .object(["count": .number(1), "name": .string("stable")]))

        // Second carries only the changed key, and no full context.
        #expect(snapshots[1].context == .object([:]))
        let delta = try #require(snapshots[1].contextDelta.flatMap(ContextDelta.fromJSON))
        #expect(delta == .merge(["count": .replace(.number(2))]))

        // …and it reconstructs the real context.
        #expect(delta.applied(to: snapshots[0].context) == .object(["count": .number(2), "name": .string("stable")]))
    }

    @Test("a keyframe is re-sent on the configured interval")
    func periodicKeyframe() async throws {
        let transport = MockInspectTransport(policy: .localhostOnly())
        let bridge = bridge(.diff(keyframeEvery: 2), transport: transport)

        await publish((1 ... 4).map { snapshotEvent(context: .object(["count": .number(Double($0))])) },
                      through: bridge, into: transport)

        let snapshots = try await publishedSnapshots(transport)
        #expect(snapshots.count == 4)
        // #0 keyframe, #1 #2 deltas, then #3 re-keys.
        #expect(snapshots[0].contextDelta == nil)
        #expect(snapshots[1].contextDelta != nil)
        #expect(snapshots[2].contextDelta != nil)
        #expect(snapshots[3].contextDelta == nil)
        #expect(snapshots[3].context == .object(["count": .number(4)]))
    }

    @Test("each actor is diffed against its own baseline")
    func perActorBaselines() async throws {
        let transport = MockInspectTransport(policy: .localhostOnly())
        let bridge = bridge(.diff(keyframeEvery: 0), transport: transport)

        await publish([
            snapshotEvent(sessionId: "a", context: .object(["v": .number(1)])),
            snapshotEvent(sessionId: "b", context: .object(["v": .number(100)])),
            snapshotEvent(sessionId: "a", context: .object(["v": .number(2)])),
        ], through: bridge, into: transport)

        let snapshots = try await publishedSnapshots(transport)
        #expect(snapshots[0].contextDelta == nil)   // a's keyframe
        #expect(snapshots[1].contextDelta == nil)   // b's own keyframe, not a delta vs a
        let delta = try #require(snapshots[2].contextDelta.flatMap(ContextDelta.fromJSON))
        #expect(delta == .merge(["v": .replace(.number(2))]))
    }

    @Test("selected publishes only the chosen keys")
    func selectedFiltersKeys() async throws {
        let transport = MockInspectTransport(policy: .localhostOnly())
        let bridge = bridge(.selected(["keep"]), transport: transport)

        await publish([snapshotEvent(context: .object([
            "keep": .string("yes"), "drop": .string("no"), "alsoDrop": .number(1),
        ]))], through: bridge, into: transport)

        let snapshots = try await publishedSnapshots(transport)
        #expect(snapshots[0].context == .object(["keep": .string("yes")]))
    }

    @Test("none publishes no context")
    func noneEmptiesContext() async throws {
        let transport = MockInspectTransport(policy: .localhostOnly())
        let bridge = bridge(.none, transport: transport)

        await publish([snapshotEvent(context: .object(["secret": .string("x")]))],
                      through: bridge, into: transport)

        let snapshots = try await publishedSnapshots(transport)
        #expect(snapshots[0].context == .object([:]))
        #expect(snapshots[0].contextDelta == nil)
    }

    @Test("full is unchanged — the default keeps today's behaviour")
    func fullIsUnchanged() async throws {
        let transport = MockInspectTransport(policy: .localhostOnly())
        let bridge = bridge(.full, transport: transport)
        let context = JSONValue.object(["count": .number(7)])

        await publish([snapshotEvent(context: context), snapshotEvent(context: context)],
                      through: bridge, into: transport)

        let snapshots = try await publishedSnapshots(transport)
        #expect(snapshots.allSatisfy { $0.contextDelta == nil })
        #expect(snapshots.allSatisfy { $0.context == context })
    }
}
