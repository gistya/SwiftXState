import Testing
@testable import SwiftXState

@Suite("Plan D — schema DSL (Phase 3a)")
struct DSLSchemaTests {
    struct TrafficContext: Sendable, Equatable {
        var cycles: Int = 0
        func incrementingCycles() -> Self { .init(cycles: cycles + 1) }
    }
    enum LightState: String, StateIdentifying { case red, green, yellow; static var _blank: LightState { .red } }
    enum LightEvent: String, EventIdentifying { case go, caution, stop; static var _blank: LightEvent { .stop } }

    struct TrafficLight: StateMachine {
        typealias Context = TrafficContext
        typealias StateID = LightState
        typealias EventID = LightEvent

        var machine: some XStateMachine {
            XState(.red)    { XTransition(on: .go,      to: .green)  }.initial()
            XState(.green)  { XTransition(on: .caution, to: .yellow) }
            XState(.yellow) {
                XTransition(on: .stop, to: .red).action { ctx in ctx.incrementingCycles() }
            }
        }
    }

    @Test func foldsToSchema() {
        let schema = TrafficLight().buildSchema()
        #expect(schema.order == [.red, .green, .yellow])
        #expect(schema.initialState == .red)
        #expect(schema.states[.red]?.isInitial == true)
        #expect(schema.states[.green]?.transitions.count == 1)
        #expect(schema.states[.green]?.transitions.first?.event == .caution)
        #expect(schema.states[.green]?.transitions.first?.target == .yellow)
        #expect(schema.states[.yellow]?.transitions.first?.action != nil)
        #expect(schema.states[.red]?.transitions.first?.action == nil)
    }

    @Test func actionTransformsContext() {
        let schema = TrafficLight().buildSchema()
        let action = schema.states[.yellow]?.transitions.first?.action
        #expect(action?(TrafficContext(cycles: 2)) == TrafficContext(cycles: 3))
    }

    @Test func guardEvaluates() {
        struct Guarded: StateMachine {
            typealias Context = Int
            typealias StateID = LightState
            typealias EventID = LightEvent
            var machine: some XStateMachine {
                XState(.red) { XTransition(on: .go, to: .green).when { ctx in ctx > 0 } }.initial()
                XState(.green) {}
            }
        }
        let g = Guarded().buildSchema().states[.red]?.transitions.first?.guard
        #expect(g?(1) == true)
        #expect(g?(0) == false)
    }

    // The String instantiation: the same DSL, untyped.
    @Test func stringDSL() {
        struct Stringly: StateMachine {
            typealias Context = Int
            typealias StateID = String
            typealias EventID = String
            var machine: some XStateMachine {
                XState("idle") { XTransition(on: "GO", to: "running") }.initial()
                XState("running") {}
            }
        }
        let schema = Stringly().buildSchema()
        #expect(schema.initialState == "idle")
        #expect(schema.states["idle"]?.transitions.first?.target == "running")
    }
}
