import Testing
@testable import SwiftXState

private struct TapPayload: Codable, Sendable, Equatable {
    let row: Int
    let col: Int
}

private struct TapEvent: Eventable, Codable, ReplayPayloadRepresentable, Equatable {
    let row: Int
    let col: Int

    var type: String { "TAP" }

    init(row: Int, col: Int) {
        self.row = row
        self.col = col
    }
}

private struct TapContext: Sendable, Equatable {
    var lastRow: Int?
    var lastCol: Int?
}

@Suite("Replay typed event payloads")
struct ReplayPayloadTests {
    private var tapMachine: StateMachine<TapContext> {
        createMachine(MachineConfig(
            id: "tap-machine",
            initial: "idle",
            context: TapContext(lastRow: nil, lastCol: nil),
            states: [
                "idle": StateNodeConfig(on: [
                    "TAP": .single(TransitionConfig(actions: [
                        assign { ctx, args in
                            guard let event = args.event as? TapEvent else { return }
                            ctx.lastRow = event.row
                            ctx.lastCol = event.col
                        },
                    ])),
                ]),
            ]
        ))
    }

    private func tapDecoder(_ replayEvent: ReplayableEvent) -> (any Eventable)? {
        guard case let .simple(type, payload) = replayEvent else { return nil }
        return replayDecodeEvent(type: type, payload: payload, as: TapEvent.self, expectedType: "TAP")
    }

    @Test("ReplayableEvent records and restores Codable payload")
    func roundTripPayload() {
        let original = TapEvent(row: 3, col: 5)
        let recorded = ReplayableEvent(from: original)

        guard case let .simple(type, payload) = recorded else {
            Issue.record("Expected simple replay event with payload")
            return
        }

        #expect(type == "TAP")
        #expect(payload?.decode(TapPayload.self) == TapPayload(row: 3, col: 5))

        let restored = recorded.makeEvent(decoder: tapDecoder)
        #expect(restored as? TapEvent == original)
    }

    @Test("InspectionRecorder captures typed payloads")
    func recorderCapturesPayload() {
        let recorder = InspectionRecorder()
        let actor = createActor(
            tapMachine,
            options: ActorOptions(inspect: recorder.observe())
        ).start(context: TapContext(lastRow: nil, lastCol: nil))

        actor.send(TapEvent(row: 1, col: 2))

        guard let session = recorder.session() else {
            Issue.record("Expected recorded session")
            return
        }

        let userSteps = session.steps.filter(\.event.isReplayable)
        #expect(userSteps.count == 1)

        guard case let .simple(_, payload) = userSteps[0].event else {
            Issue.record("Expected payload on recorded step")
            return
        }
        #expect(payload?.decode(TapPayload.self) == TapPayload(row: 1, col: 2))
    }

    @Test("pure replay with decoder matches recorded session")
    func verifyPayloadReplay() {
        let recorder = InspectionRecorder()
        let actor = createActor(
            tapMachine,
            options: ActorOptions(inspect: recorder.observe())
        ).start(context: TapContext(lastRow: nil, lastCol: nil))

        actor.send(TapEvent(row: 4, col: 6))

        guard let session = recorder.session() else {
            Issue.record("Expected recorded session")
            return
        }

        let verifications = verifyReplay(
            tapMachine,
            context: TapContext(lastRow: nil, lastCol: nil),
            session: session,
            decodeEvent: tapDecoder
        )
        #expect(verifications.filter { !$0.matches }.isEmpty)

        let traveled = timeTravel(
            tapMachine,
            context: TapContext(lastRow: nil, lastCol: nil),
            session: session,
            toStep: 1,
            decodeEvent: tapDecoder
        )
        #expect(traveled?.context.lastRow == 4)
        #expect(traveled?.context.lastCol == 6)
    }

    @Test("ReplaySession JSON round-trips typed payloads")
    func jsonRoundTrip() throws {
        let recorder = InspectionRecorder()
        let actor = createActor(
            tapMachine,
            options: ActorOptions(inspect: recorder.observe())
        ).start(context: TapContext(lastRow: nil, lastCol: nil))
        actor.send(TapEvent(row: 2, col: 7))

        guard let session = recorder.session() else {
            Issue.record("Expected recorded session")
            return
        }

        let decoded = try ReplaySession.decodeJSON(try session.encodeJSON())
        let verifications = verifyReplay(
            tapMachine,
            context: TapContext(lastRow: nil, lastCol: nil),
            session: decoded,
            decodeEvent: tapDecoder
        )
        #expect(verifications.filter { !$0.matches }.isEmpty)
    }

    @Test("type-only events remain backward compatible")
    func simpleTypeOnlyEvents() {
        let recorded = ReplayableEvent(from: Event("INC"))
        guard case let .simple(type, payload) = recorded else {
            Issue.record("Expected simple replay event")
            return
        }
        #expect(type == "INC")
        #expect(payload == nil)
        #expect(recorded.makeEvent().type == "INC")
    }
}