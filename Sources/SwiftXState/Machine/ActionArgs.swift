/// The arguments every guard and action receives: the current `context` and the triggering `event`.
public struct ActionArgs<Context: Sendable>: Sendable {
    /// The machine's current context.
    public let context: Context
    /// The event that triggered this guard/action. Downcast it (or use the Tier-2 typed API).
    public let event: any Eventable

    public init(context: Context, event: any Eventable) {
        self.context = context
        self.event = event
    }
}
