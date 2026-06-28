#if SWIFTXSTATE_APPLE_UI
import Testing
import SwiftUI
@testable import SwiftXState
@testable import SwiftXStateSwiftUI

@MainActor
private func waitUntil(_ condition: @MainActor () -> Bool, iterations: Int = 10_000) async {
    var remaining = iterations
    while !condition(), remaining > 0 {
        await Task.yield()
        remaining -= 1
    }
}

@MainActor
@Suite("Plan D x SwiftUI — MachineView / @Machine")
struct MachineViewTests {
    @Test func activeLeafSelection() {
        // atomic → the single active leaf
        #expect(activeLeaves(of: Configuration<DemoLight>.atomic(.green)) == [.green])
        // nil → nothing to render
        #expect(activeLeaves(of: Configuration<DemoLight>?.none) == [])
        // parallel/nested → all active leaves, sorted by name ("green" < "red")
        let nested = Configuration<DemoLight>.nested([
            .red: .atomic(.green),
            .yellow: .atomic(.red),
        ])
        #expect(activeLeaves(of: nested) == [.green, .red])
    }

    @Test func demoMachineRunsThroughStore() async {
        let light = MachineStore(DemoTrafficLight())
        await waitUntil { light.matches(.red) }
        light.send(.go)
        await waitUntil { light.matches(.green) }
        light.send(.caution)
        await waitUntil { light.matches(.yellow) }
        light.send(.stop)
        await waitUntil { light.matches(.red) && light.context.cycles == 1 }
        #expect(light.context.cycles == 1)
    }

    @Test func machineViewRendersActiveState() async {
        let light = MachineStore(DemoTrafficLight())
        await waitUntil { light.configuration == .atomic(.red) }

        // The view selects content for the active leaf; rendering it proves the View builds and the
        // active state is wired through. (ImageRenderer is the project's SwiftUI smoke-test technique.)
        let view = MachineView(light) { state, _ in
            Text(state.name).frame(width: 200, height: 120)
        }
        let renderer = ImageRenderer(content: view)
        #expect(renderer.cgImage != nil)
    }
}
#endif
