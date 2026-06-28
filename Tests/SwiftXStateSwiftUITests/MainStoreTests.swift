#if SWIFTXSTATE_APPLE_UI
import Testing
@testable import SwiftXState
@testable import SwiftXStateSwiftUI

/// Poll `condition` on the main actor without sleeping — converges in a few yields once the
/// off-main actor's update has hopped back to main. Bounded so a wrong assertion fails fast.
@MainActor
private func waitUntil(
    _ condition: @MainActor () -> Bool,
    iterations: Int = 10_000
) async {
    var remaining = iterations
    while !condition(), remaining > 0 {
        await Task.yield()
        remaining -= 1
    }
}

@MainActor
@Suite("Plan D — MainStore / MachineStore (main-actor membrane)")
struct MainStoreTests {
    struct TrafficContext: Sendable, Equatable {
        var cycles: Int = 0
        func incrementingCycles() -> Self { .init(cycles: cycles + 1) }
    }
    enum Light: String, StateIdentifying { case red, green, yellow; static var _blank: Light { .red } }
    enum LightEvent: String, EventIdentifying { case go, caution, stop; static var _blank: LightEvent { .stop } }

    struct TrafficLight: StateMachine {
        typealias Context = TrafficContext
        typealias StateID = Light
        typealias EventID = LightEvent
        var context: TrafficContext { .init() }
        var machine: some XStateMachine {
            XState(.red)    { XTransition(on: .go,      to: .green)  }.initial()
            XState(.green)  { XTransition(on: .caution, to: .yellow) }
            XState(.yellow) { XTransition(on: .stop, to: .red).action { $0.incrementingCycles() } }
        }
    }

    enum Toggle: String, StateIdentifying { case off, on; static var _blank: Toggle { .off } }
    enum ToggleEvent: String, EventIdentifying { case flip; static var _blank: ToggleEvent { .flip } }
    struct Switch: StateMachine {
        typealias Context = Int
        typealias StateID = Toggle
        typealias EventID = ToggleEvent
        var context: Int { 0 }
        var machine: some XStateMachine {
            XState(.off) { XTransition(on: .flip, to: .on) }.initial()
            XState(.on)  { XTransition(on: .flip, to: .off) }
        }
    }

    @Test func machineStoreReflectsStartAndSendOnMain() async {
        let store = MachineStore(TrafficLight())

        await waitUntil { store.configuration == .atomic(.red) }
        #expect(store.matches(.red))

        store.send(.go)
        await waitUntil { store.matches(.green) }
        #expect(store.configuration == .atomic(.green))

        store.send(.caution)
        await waitUntil { store.matches(.yellow) }

        store.send(.stop)
        await waitUntil { store.matches(.red) && store.context.cycles == 1 }
        #expect(store.context.cycles == 1)   // the yellow→red action flowed to main
    }

    @Test func mainStoreCollatesMultipleActors() async {
        let main = MainStore()
        let light = main.track(TrafficLight())   // keyed by type; hold the typed handle
        let toggle = main.track(Switch())

        #expect(main.count == 2)
        await waitUntil { light.configuration != nil && toggle.configuration != nil }

        // Independent typed updates, both collated on main.
        light.send(.go)
        toggle.send(.flip)
        await waitUntil { light.matches(.green) && toggle.matches(.on) }
        #expect(light.matches(.green))
        #expect(toggle.matches(.on))

        // Typed lookup back out of the collator — by type, no string, no cast.
        #expect(main.store(TrafficLight.self)?.matches(.green) == true)
        #expect(main.store(Switch.self)?.matches(.on) == true)
        // A type that isn't tracked is a safe nil.
        #expect(main.store(Unused.self) == nil)
    }

    @Test func sameTypeMultiplesViaTypedKey() async {
        let main = MainStore()
        let north = main.track(TrafficLight(), key: .north)
        let south = main.track(TrafficLight(), key: .south)
        #expect(main.count == 2)
        await waitUntil { north.configuration != nil && south.configuration != nil }

        north.send(.go)
        await waitUntil { north.matches(.green) }
        // Independent instances, distinguished by typed key — north advanced, south didn't.
        #expect(main.store(.north)?.matches(.green) == true)
        #expect(main.store(.south)?.matches(.red) == true)
    }

    @Test func erasedDashboardFaceAndUntrack() async {
        let main = MainStore()
        let light = main.track(TrafficLight())
        await waitUntil { main.store(TrafficLight.self)?.configurationDescription != nil }

        // Dashboard iterates the erased faces; identity is the engine session id, not a user string.
        let face = main.all.first { $0.id == light.id }
        #expect(face?.typeName == "TrafficLight")
        #expect(face?.statusDescription == "active")
        #expect(face?.configurationDescription == "red")

        main.untrack(TrafficLight.self)
        #expect(main.count == 0)
        #expect(main.store(TrafficLight.self) == nil)
    }
}

// A machine never tracked, to prove a missing-type lookup is a safe nil.
private enum UnusedState: String, StateIdentifying { case only; static var _blank: UnusedState { .only } }
private enum UnusedEvent: String, EventIdentifying { case noop; static var _blank: UnusedEvent { .noop } }
private struct Unused: StateMachine {
    typealias Context = Int
    typealias StateID = UnusedState
    typealias EventID = UnusedEvent
    var context: Int { 0 }
    var machine: some XStateMachine { XState(.only) {}.initial() }
}

private extension MachineKey where M == MainStoreTests.TrafficLight {
    static var north: Self { .init("north") }
    static var south: Self { .init("south") }
}
#endif
