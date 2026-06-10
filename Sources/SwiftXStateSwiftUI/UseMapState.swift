#if SWIFTXSTATE_APPLE_UI
import SwiftUI
import SwiftXState

/// Selects the most specific mapped value from a machine snapshot, re-rendering only when it changes.
/// Mirrors XState's `mapState` + first-match semantics for view models.
///
/// Like `useSelector`, the returned value is captured at call time. The internal driver
/// subscribes for future changes, but because a fresh driver is created on every view
/// body evaluation, SwiftUI does not track it for automatic invalidation.
/// 
/// For reliable observation in complex UIs, prefer a stable @Observable (e.g. your
/// Session exposing a `viewState` computed via `snapshot.mapStateFirst(...)`) or the
/// `MachineState` / `StoreState` property-wrapper patterns. This hook is best for
/// convenient one-off derivations when the parent view already re-renders for other reasons.
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
        self.value = mapStateFirst(actor.snapshot, mapper: mapper)
        self.subscription = actor.subscribe { [weak self] snapshot in
            guard let self else { return }
            let next = mapStateFirst(snapshot, mapper: mapper)
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
public func useMapState<Context: Sendable, T: Sendable & Equatable>(
    _ actor: Actor<Context>,
    _ mapper: StateMap<Context, T>
) -> T? {
    MapStateDriver(actor: actor, mapper: mapper).value
}
#endif
