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
    typealias Always = XAlways<Context, EventID, StateID>
    typealias After = XAfter<Context, EventID, StateID>
    typealias OnDone = XOnDone<Context, EventID, StateID>
    typealias Invoke = XInvoke<Context, EventID, StateID>
    typealias State = XState<Context, EventID, StateID>
    typealias Transition = XTransition<Context, EventID, StateID>
    
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

    /// Whether the inspector graph should auto-lay-out this machine (the layered/Sugiyama engine that
    /// spaces states, routes edges through channels, and disambiguates parallel transitions). Defaults
    /// to `true`. Set `var useAutoLayoutForInspection: Bool { false }` for a machine whose states carry
    /// their own meaningful geometry — e.g. a chess board's 8×8 grid — so the inspector preserves that
    /// fixed arrangement (via `GraphStyle.nodeLayoutOverride`) instead of reflowing it.
    var useAutoLayoutForInspection: Bool { get }

    /// Event cases that may be **raised from within** the machine (`enq.raise(...)`) but are
    /// **rejected when sent from outside** (XState v6 `internalEvents`). Typed — declared with the
    /// machine's own `EventID` cases and lowered to their `name`s. Defaults to none; override with
    /// e.g. `var internalEvents: [Event] { [.tick, .settle] }`.
    var internalEvents: [EventID] { get }

    @MachineBuilder<Context, EventID, StateID>
    var machine: Body { get }
}

public extension StateMachine {
    /// Sequential root by default.
    var isParallel: Bool { false }

    /// No internal-only events by default.
    var internalEvents: [EventID] { [] }

    /// Auto-layout the inspector graph by default.
    var useAutoLayoutForInspection: Bool { true }

    /// Fold the declarative `machine` block into a concrete `MachineSchema`, carrying the root-parallel
    /// and inspector-auto-layout flags.
    func buildSchema() -> MachineSchema<Context, EventID, StateID> {
        machine.folded(into: MachineSchema<Context, EventID, StateID>())
            .withParallel(isParallel)
            .withAutoLayout(useAutoLayoutForInspection)
    }
}
