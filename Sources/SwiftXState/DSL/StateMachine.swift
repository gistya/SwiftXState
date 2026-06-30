/// A state machine declared the way you declare a SwiftUI `View`: conform a type, give it a
/// `Context` / `EventID` / `StateID`, and describe the chart in a `@MachineBuilder` `machine` block.
///
/// ```swift
/// struct TrafficLight: StateMachine {
///     typealias Context = TrafficContext
///     typealias StateID = Light.State
///     typealias EventID = Light.Event
///
///     var context: TrafficContext { .init() }
///
///     var machine: some XStateMachine {
///         XState(.red)    { XTransition(on: .go,      to: .green)  }.initial()
///         XState(.green)  { XTransition(on: .caution, to: .yellow) }
///         XState(.yellow) { XTransition(on: .stop,    to: .red)    }
///     }
/// }
/// ```
public protocol StateMachine<Context, EventID, StateID>: MachineSchemable, Sendable {
    /// The element type of the `machine` block — any machine component for this schema identity.
    typealias XStateMachine = SchemaReducible<Context, EventID, StateID>

    associatedtype Body: XStateMachine

    /// The machine's initial context — XState v6's `createMachine({ context })`. Declared on the
    /// machine (evaluated fresh per actor) so `createActor(machine).start()` needs no context
    /// argument; an explicit `start(context:)` override still wins. The input-derived form
    /// (`context: ({ input }) => …`) arrives with the typed-input phase.
    var context: Context { get }

    /// Whether the machine *root* is parallel — XState v6's `createMachine({ type: 'parallel' })`:
    /// every top-level state runs simultaneously, with no `initial`. Defaults to `false`; override
    /// with `var isParallel: Bool { true }` for a parallel-root machine (e.g. a board of independent
    /// squares). The per-state analogue is `XState(...).parallel()`.
    var isParallel: Bool { get }

    @MachineBuilder<Context, EventID, StateID>
    var machine: Body { get }
}

public extension StateMachine {
    /// Sequential root by default.
    var isParallel: Bool { false }

    /// Fold the declarative `machine` block into a concrete `MachineSchema`, carrying the root-parallel flag.
    func buildSchema() -> MachineSchema<Context, EventID, StateID> {
        machine.folded(into: MachineSchema<Context, EventID, StateID>()).withParallel(isParallel)
    }
}
