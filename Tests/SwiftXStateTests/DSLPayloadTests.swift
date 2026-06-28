import Testing
import CompositionalInit
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
                // Payload cases referenced by their case initializer — no placeholder value.
                XTransition(on: CounterEvent.increment, to: .active).action { args, _ in
                    guard case let .increment(by)? = args.event else { return args.context }
                    return args.context + by
                }
                XTransition(on: CounterEvent.set, to: .active).action { args, _ in
                    guard case let .set(value)? = args.event else { return args.context }
                    return value
                }
                // A payloadless case still uses the plain form.
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

    @Test func casePathRoutingComposesWithGuard() async {
        // Explicit CasePath form + a context guard: only large increments are accepted.
        struct Picky: StateMachine {
            typealias Context = Int
            typealias StateID = CounterState
            typealias EventID = CounterEvent
            var context: Int { 0 }
            var machine: some XStateMachine {
                XState(.active) {
                    XTransition(on: CasePath(CounterEvent.increment), to: .active)
                        .when { $0 < 10 }                 // guard on context
                        .action { args, _ in
                            guard case let .increment(by)? = args.event else { return args.context }
                            return args.context + by
                        }
                }.initial()
            }
        }
        let m = createActor(Picky())
        await m.start()
        await m.send(.increment(by: 5))     // ctx 0 < 10 → +5
        #expect(await m.context == 5)
        await m.send(.increment(by: 5))     // ctx 5 < 10 → +5
        #expect(await m.context == 10)
        await m.send(.increment(by: 5))     // ctx 10, guard fails → unchanged
        #expect(await m.context == 10)
        await m.send(.reset)                // not the increment case → no matching transition, no-op
        #expect(await m.context == 10)
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
