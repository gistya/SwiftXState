/// A declarative side effect a logic asks the runtime to perform (modelled on XState v6's
/// `LogicEffect` — `emit` / `sendBack` / `raise`). `Actor` executes these through one serial
/// chain, so a child's outbound deliveries keep their order centrally — no per-child delivery chain,
/// and the historical `sendToParent`-before-`onDone` race can't recur.
enum LogicEffect: Sendable {
    /// Notify `on(_:)` emit listeners.
    case emit(EmittedEvent)
    /// Send an event up to the parent actor (XState's `sendBack`).
    case sendToParent(any Eventable)
    /// Deliver an event back to this actor (XState's `raise`).
    case deliverToSelf(any Eventable)
}
