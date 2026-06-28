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
        let light = main.track(TrafficLight(), id: "light")
        let toggle = main.track(Switch(), id: "toggle")

        #expect(main.ids.count == 2)
        await waitUntil { light.configuration != nil && toggle.configuration != nil }

        // Independent typed updates, both collated on main.
        light.send(.go)
        toggle.send(.flip)
        await waitUntil { light.matches(.green) && toggle.matches(.on) }
        #expect(light.matches(.green))
        #expect(toggle.matches(.on))

        // Typed lookup back out of the collator.
        #expect(main.store("light", as: TrafficLight.self)?.matches(.green) == true)
        #expect(main.store("toggle", as: Switch.self)?.matches(.on) == true)
        // Wrong-type lookup is a safe nil.
        #expect(main.store("light", as: Switch.self) == nil)
    }

    @Test func erasedDashboardFaceAndUntrack() async {
        let main = MainStore()
        main.track(TrafficLight(), id: "light")
        await waitUntil { main.anyStore("light")?.configurationDescription != nil }

        let face = main.anyStore("light")
        #expect(face?.statusDescription == "active")
        #expect(face?.configurationDescription == "red")

        main.untrack("light")
        #expect(main.ids.isEmpty)
        #expect(main.anyStore("light") == nil)
    }
}
#endif
