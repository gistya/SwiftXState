import Foundation

/// A compile-time-checked state reference — the raw value is the dot-path from the machine root
/// (`"red.wait"`). Declare a conformer as a `String`-backed enum with one case per state, so the
/// set of cases can never drift from the declared states.
///
/// ```swift
/// enum AppState: String, StateName {
///     case idle
///     case running
///     case runningFast = "running.fast"   // nested: compound name, dotted raw value
/// }
/// ```
///
/// Targets are emitted as `#`-absolute ids, which resolve no matter where the transition is
/// declared — sidestepping relative-target ambiguity.
public protocol StateName: RawRepresentable, Sendable where RawValue == String {}

public extension StateName {
    /// The absolute transition target string for this state (e.g. `"#red.wait"`).
    var target: String { "#\(rawValue)" }
}

// MARK: - Typed targets (Tier 2)

public extension TransitionInput {
    /// Type-safe transition target from a generated `StateName`.
    static func to<S: StateName>(_ state: S) -> TransitionInput<Context> {
        .target(state.target)
    }
}

/// Typed `on(...)` transition with a compile-checked `StateName` target.
public func on<Context: Sendable, E: StateEvent, S: StateName>(
    _ event: E.Type,
    to state: S,
    reenter: Bool? = nil,
    guard guardRef: GuardRef<Context>? = nil,
    actions: [ActionRef<Context>] = []
) -> EventTransition<Context> {
    on(event, target: state.target, reenter: reenter, guard: guardRef, actions: actions)
}
