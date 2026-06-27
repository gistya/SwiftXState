/// A state machine declared the way you declare a SwiftUI `View`: conform a type, give it a
/// `Context` / `EventID` / `StateID`, and describe the chart in a `@MachineBuilder` `machine` block.
///
/// ```swift
/// struct TrafficLight: StateMachine {
///     typealias Context = TrafficContext
///     typealias StateID = Light.State
///     typealias EventID = Light.Event
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

    @MachineBuilder<Context, EventID, StateID>
    var machine: Body { get }
}

public extension StateMachine {
    /// Fold the declarative `machine` block into a concrete `MachineSchema`.
    func buildSchema() -> MachineSchema<Context, EventID, StateID> {
        machine.folded(into: MachineSchema<Context, EventID, StateID>())
    }
}
