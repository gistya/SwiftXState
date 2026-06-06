import Foundation

// MARK: - Tier 2: typed events with per-event narrowing
//
// This is an *opt-in* layer over the string-keyed Tier-1 API. You model each event as its own
// type; transitions are keyed by that type, and guard/action closures receive the **concrete**
// event — no `as?` cast, no `assertEvent`. Everything here compiles down to ordinary
// `TransitionConfig` / `ActionRef` / `GuardRef`, so the engine, `definitionJSON()` export, and the
// inspector behave identically to a hand-written Tier-1 machine.
//
// Tier 1 (XState-familiar):                Tier 2 (Swift-native, narrowed):
//   on: ["input.change": .to("Debouncing")]   on: transitions(
//                                                on(InputChange.self, target: "Debouncing",
//                                                   actions: [assign { (c: inout Ctx, e: InputChange) in
//                                                       c.searchInput = e.searchInput }]))

/// An event modeled as its own type. The `eventType` string is what flows to the wire format,
/// `definitionJSON()`, and the inspector — defaulting to the type name, override for XState-style
/// dotted names (e.g. `"input.change"`).
public protocol StateEvent: Eventable {
    static var eventType: String { get }
}

public extension StateEvent {
    static var eventType: String { String(describing: Self.self) }
    var type: String { Self.eventType }
}

// MARK: Typed guard / action helpers

/// A guard that receives the concrete event `E`. Fails closed (returns `false`) if the runtime
/// event isn't an `E` — which can't happen for a transition keyed on `E`, but keeps it total.
public func guarded<Context: Sendable, E: StateEvent>(
    on _: E.Type = E.self,
    _ body: @escaping @Sendable (_ context: Context, _ event: E) -> Bool
) -> GuardRef<Context> {
    .inline { args in
        guard let event = args.event as? E else { return false }
        return body(args.context, event)
    }
}

/// An `assign` action whose mutating closure receives the concrete event `E`. No-ops if the
/// runtime event isn't an `E` (unreachable for an `E`-keyed transition).
public func assign<Context: Sendable, E: StateEvent>(
    on _: E.Type = E.self,
    _ body: @escaping @Sendable (_ context: inout Context, _ event: E) -> Void
) -> ActionRef<Context> {
    assign { (context: inout Context, args: ActionArgs<Context>) in
        guard let event = args.event as? E else { return }
        body(&context, event)
    }
}

// MARK: Typed transitions

/// One typed `on`-transition, keyed by its event type. Build with `on(_:target:guard:actions:)`
/// and assemble with `transitions(_:)`.
public struct EventTransition<Context: Sendable>: Sendable {
    public let eventType: String
    public let config: TransitionConfig<Context>
}

/// Declare a transition for event type `E`. The returned entry is keyed by `E.eventType`.
public func on<Context: Sendable, E: StateEvent>(
    _ event: E.Type,
    target: String? = nil,
    reenter: Bool? = nil,
    guard guardRef: GuardRef<Context>? = nil,
    actions: [ActionRef<Context>] = []
) -> EventTransition<Context> {
    EventTransition(
        eventType: E.eventType,
        config: TransitionConfig(
            target: target,
            guard: guardRef,
            actions: actions.isEmpty ? nil : actions,
            reenter: reenter
        )
    )
}

/// Assemble typed `on(...)` entries into the `[String: TransitionInput]` dictionary that
/// `StateNodeConfig(on:)` expects. Multiple entries for the same event become an ordered
/// guarded list (first matching guard wins), mirroring XState.
public func transitions<Context: Sendable>(
    _ entries: EventTransition<Context>...
) -> [String: TransitionInput<Context>] {
    transitions(entries)
}

/// Array form of `transitions(_:)`, for building entries programmatically.
public func transitions<Context: Sendable>(
    _ entries: [EventTransition<Context>]
) -> [String: TransitionInput<Context>] {
    var grouped: [String: [TransitionConfig<Context>]] = [:]
    var order: [String] = []
    for entry in entries {
        if grouped[entry.eventType] == nil { order.append(entry.eventType) }
        grouped[entry.eventType, default: []].append(entry.config)
    }
    var out: [String: TransitionInput<Context>] = [:]
    for key in order {
        let configs = grouped[key]!
        out[key] = configs.count == 1 ? .single(configs[0]) : .multiple(configs)
    }
    return out
}
