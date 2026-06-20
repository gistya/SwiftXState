#if SWIFTXSTATE_APPLE_UI
import SwiftUI
import SwiftXState

private final class WeakSelectorDriverBox<Object: AnyObject>: @unchecked Sendable {
    weak var object: Object?

    init(_ object: Object) {
        self.object = object
    }
}

/// Selects a derived value from a machine snapshot, re-rendering only when the selection changes.
/// Mirrors XState React's `useSelector()`.
@MainActor
@Observable
public final class SelectorDriver<Context: Sendable, T: Sendable & Equatable> {
    public private(set) var value: T?
    private let selector: @Sendable (MachineSnapshot<Context>) -> T
    @ObservationIgnored private var subscription: Subscription?

    public init(
        actor: Actor<Context>,
        selector: @escaping @Sendable (MachineSnapshot<Context>) -> T
    ) {
        self.selector = selector

        let box = WeakSelectorDriverBox(self)
        Task { [box, actor, selector] in
            let initial = selector(await actor.snapshot)
            let subscription = await actor.subscribe { snapshot in
                let next = selector(snapshot)
                Task { @MainActor [box] in
                    guard let driver = box.object, driver.value != next else { return }
                    driver.value = next
                }
            }
            await MainActor.run { [box] in
                box.object?.value = initial
                box.object?.subscription = subscription
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
    _ selector: @escaping @Sendable (MachineSnapshot<Context>) -> T
) -> T? {
    SelectorDriver(actor: actor, selector: selector).value
}
#endif
