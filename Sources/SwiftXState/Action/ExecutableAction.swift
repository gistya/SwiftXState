/// An executable action captured during a transition (not yet executed).
public struct ExecutableAction<Context: Sendable>: Sendable {
    public let ref: ActionRef<Context>
    public let type: String
    public var delayedEvent: Event?
    public var delayMs: Int?
    public var timerId: String?

    init(
        ref: ActionRef<Context>,
        delayedEvent: Event? = nil,
        delayMs: Int? = nil,
        timerId: String? = nil
    ) {
        self.ref = ref
        self.type = actionType(for: ref)
        self.delayedEvent = delayedEvent
        self.delayMs = delayMs
        self.timerId = timerId
    }
}
