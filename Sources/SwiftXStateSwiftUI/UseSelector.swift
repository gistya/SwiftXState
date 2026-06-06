#if SWIFTXSTATE_APPLE_UI
import SwiftUI
import SwiftXState

/// Selects a derived value from a machine snapshot, re-rendering only when the selection changes.
/// Mirrors XState React's `useSelector()`.
@MainActor
@Observable
public final class SelectorDriver<Context: Sendable, T: Sendable & Equatable> {
    public private(set) var value: T
    private let selector: (MachineSnapshot<Context>) -> T
    private nonisolated(unsafe) var subscription: Subscription?

    public init(
        actor: Actor<Context>,
        selector: @escaping (MachineSnapshot<Context>) -> T
    ) {
        self.selector = selector
        self.value = selector(actor.snapshot)
        self.subscription = actor.subscribe { [weak self] snapshot in
            guard let self else { return }
            let next = self.selector(snapshot)
            if self.value != next {
                Task { @MainActor in
                    self.value = next
                }
            }
        }
    }

    deinit {
        subscription?.cancel()
    }
}

@MainActor
public func useSelector<Context: Sendable, T: Sendable & Equatable>(
    _ actor: Actor<Context>,
    _ selector: @escaping (MachineSnapshot<Context>) -> T
) -> T {
    SelectorDriver(actor: actor, selector: selector).value
}
#endif