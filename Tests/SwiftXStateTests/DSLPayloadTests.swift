import Testing
@testable import SwiftXState

@Suite("Plan D — event payloads (associated-value EventID)")
struct DSLPayloadTests {
    enum CounterState: String, StateIdentifying { case active; static var _blank: CounterState { .active } }

    /// An event union with payloads — XState v6's `{ type: 'increment', by: n }`, as a Swift enum.
    enum CounterEvent: EventIdentifying {
        case increment(by: Int)
        case set(Int)
        case reset
        static var _blank: CounterEvent { .reset }
    }

    struct Counter: StateMachine {
        typealias Context = Int
        typealias StateID = CounterState
        typealias EventID = CounterEvent
        var context: Int { 0 }
        var machine: some XStateMachine {
            XState(.active) {
                // The payload placeholders below are ignored for routing — only the discriminant
                // (`increment` / `set` / `reset`) keys the transition; the real payload arrives at send.
                XTransition(on: .increment(by: 0), to: .active).action { args, _ in
                    guard case let .increment(by)? = args.event else { return args.context }
                    return args.context + by
                }
                XTransition(on: .set(0), to: .active).action { args, _ in
                    guard case let .set(value)? = args.event else { return args.context }
                    return value
                }
                XTransition(on: .reset, to: .active).action { _, _ in 0 }
            }
            .initial()
        }
    }

    @Test func discriminantIgnoresPayload() {
        // Routing key is the case label, regardless of the associated value.
        #expect(CounterEvent.increment(by: 5).name == "increment")
        #expect(CounterEvent.increment(by: 999).name == "increment")
        #expect(CounterEvent.set(3).name == "set")
        #expect(CounterEvent.reset.name == "reset")
    }

    @Test func handlerReadsSentPayload() async {
        let c = createActor(Counter())
        await c.start()
        #expect(await c.context == 0)

        await c.send(.increment(by: 5))
        #expect(await c.context == 5)

        await c.send(.increment(by: 3))
        #expect(await c.context == 8)

        await c.send(.set(100))
        #expect(await c.context == 100)

        await c.send(.reset)
        #expect(await c.context == 0)
    }

    @Test func typedEventRoundTripsThroughEngine() async {
        // The engine event preserves the typed id, recoverable as TypedEvent<EventID>.
        let typed = CounterEvent.increment(by: 42).event
        #expect(typed.type == "increment")
        #expect((typed as any Eventable) as? TypedEvent<CounterEvent> != nil)
        if case let .increment(by)? = (typed as? TypedEvent<CounterEvent>)?.id {
            #expect(by == 42)
        } else {
            Issue.record("expected increment payload")
        }
    }
}
