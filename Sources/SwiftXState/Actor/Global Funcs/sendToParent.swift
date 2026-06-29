/// An action that sends an event to this actor's parent. XState's `sendToParent`.
public func sendToParent<Context: Sendable>(_ event: Event) -> ActionRef<Context> {
    .sendToParent(event)
}
