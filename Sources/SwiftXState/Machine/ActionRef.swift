/// A reference to an action. Build these with the helper functions (`assign`, `sendTo`, `raise`,
/// `log`, `spawnChild`, …) rather than constructing cases directly.
public enum ActionRef<Context: Sendable>: Sendable {
    /// A guard/action registered by name via `setup(actions:)`.
    case named(String)
    /// A named action with bound parameters (see `actionRef(_:params:)`).
    case parameterized(String, ParamsBox)
    /// Update context (`assign { … }`).
    case assign(AssignAction<Context>)
    /// An inline, unnamed action closure.
    case inline(@Sendable (ActionArgs<Context>) -> Void)
    /// Spawn a child actor.
    case spawn(SpawnRef<Context>)
    /// Stop a spawned/invoked child.
    case stopChild(ChildTarget<Context>)
    /// Forward the current event to a child.
    case forwardTo(ChildTarget<Context>)
    /// Send an event to another actor.
    case sendTo(SendToAction<Context>)
    /// Send an event to the parent actor.
    case sendParent(Event)
    /// Raise an event back into this machine (processed in the same or a later step).
    case raise(RaiseAction<Context>)
    /// Cancel a previously-scheduled delayed `raise`/`sendTo` by id.
    case cancel(CancelId<Context>)
    /// Imperatively enqueue actions/guards (`enqueueActions { … }`).
    case enqueueActions(@Sendable (EnqueueActionsBuilder<Context>) -> Void)
    /// Emit a log line.
    case log(LogAction<Context>)
    /// Emit an event to external subscribers.
    case emit(EmitAction<Context>)
}
