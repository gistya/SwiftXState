#if SWIFTXSTATE_APPLE_UI
import SwiftUI
import SwiftXState

/// Observable wrapper for a Store in SwiftUI views.
@MainActor
@Observable
public final class StoreDriver<Context: Sendable & Equatable, E: Eventable> {
    public private(set) var snapshot: StoreSnapshot<Context>
    public let store: Store<Context, E>

    public init(_ store: Store<Context, E>) {
        self.store = store
        self.snapshot = store.snapshot
        _ = store.subscribe { [weak self] snapshot in
            Task { @MainActor in
                self?.snapshot = snapshot
            }
        }
    }

    public func send(_ event: E) {
        store.send(event)
        snapshot = store.snapshot
    }
}

@MainActor
public func useStore<Context: Sendable & Equatable, E: Eventable>(
    _ store: Store<Context, E>
) -> (snapshot: StoreSnapshot<Context>, send: (E) -> Void, store: Store<Context, E>) {
    let driver = StoreDriver(store)
    return (
        driver.snapshot,
        { driver.send($0) },
        driver.store
    )
}

/// Property wrapper for embedding a store in a SwiftUI view.
@propertyWrapper
@MainActor
public struct StoreState<Context: Sendable & Equatable, E: Eventable>: DynamicProperty {
    @State private var driver: StoreDriver<Context, E>

    public init(_ store: Store<Context, E>) {
        _driver = State(initialValue: StoreDriver(store))
    }

    public var wrappedValue: StoreSnapshot<Context> {
        driver.snapshot
    }

    public var projectedValue: StoreDriver<Context, E> {
        driver
    }
}
#endif