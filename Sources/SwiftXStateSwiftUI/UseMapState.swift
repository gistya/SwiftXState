#if SWIFTXSTATE_APPLE_UI
import SwiftUI
import SwiftXState

private final class WeakMapStateDriverBox<Object: AnyObject>: @unchecked Sendable {
    weak var object: Object?

    init(_ object: Object) {
        self.object = object
    }
}

/// Selects the most specific mapped value from a machine snapshot, re-rendering only when it changes.
/// Mirrors XState's `mapState` + first-match semantics for view models.
@MainActor
@Observable
public final class MapStateDriver<Context: Sendable, T: Sendable & Equatable> {
    public private(set) var value: T?
    private let mapper: StateMap<Context, T>
    @ObservationIgnored private var subscription: Subscription?

    public init(
        actor: Actor<Context>,
        mapper: StateMap<Context, T>
    ) {
        self.mapper = mapper

        let box = WeakMapStateDriverBox(self)
        Task { [box, actor, mapper] in
            let initial = mapStateFirst(await actor.snapshot, mapper: mapper)
            let subscription = await actor.subscribe { snapshot in
                let next = mapStateFirst(snapshot, mapper: mapper)
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
public func useMapState<Context: Sendable, T: Sendable & Equatable>(
    _ actor: Actor<Context>,
    _ mapper: StateMap<Context, T>
) -> T? {
    MapStateDriver(actor: actor, mapper: mapper).value
}
#endif
