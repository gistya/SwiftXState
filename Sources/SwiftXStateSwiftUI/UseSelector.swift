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
    @ObservationIgnored private var subscription: Subscription?

    public init(
        reactor: Reactor<Context>,
        selector: @escaping (MachineSnapshot<Context>) -> T
    ) {
        self.selector = selector
        self.value = selector(reactor.snapshot)
        self.subscription = reactor.subscribe { [weak self] snapshot in
            guard let self else { return }
            let next = self.selector(snapshot)
            if self.value != next {
                Task { @MainActor in
                    self.value = next
                }
            }
        }
    }

    isolated deinit {
        subscription?.cancel()
    }
}

@MainActor
public func useSelector<Context: Sendable, T: Sendable & Equatable>(
    _ reactor: Reactor<Context>,
    _ selector: @escaping (MachineSnapshot<Context>) -> T
) -> T {
    SelectorDriver(reactor: reactor, selector: selector).value
}
#endif
