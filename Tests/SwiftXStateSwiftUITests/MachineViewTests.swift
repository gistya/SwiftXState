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

    // A parallel machine: two regions active at once (the AND case).
    enum Fmt: String, StateIdentifying, CaseIterable {
        case editing, bold, underline, on, off
        static var _blank: Fmt { .editing }
    }
    enum FmtEvent: String, EventIdentifying { case toggleBold, toggleUnderline; static var _blank: FmtEvent { .toggleBold } }
    struct Editor: StateMachine {
        typealias Context = Int
        typealias StateID = Fmt
        typealias EventID = FmtEvent
        var context: Int { 0 }
        var machine: some XStateMachine {
            XState(.editing) {
                XState(.bold) {
                    XState(.off) { XTransition(on: .toggleBold, to: .on) }.initial()
                    XState(.on) { XTransition(on: .toggleBold, to: .off) }
                }
                XState(.underline) {
                    XState(.off) { XTransition(on: .toggleUnderline, to: .on) }.initial()
                    XState(.on) { XTransition(on: .toggleUnderline, to: .off) }
                }
            }
            .parallel()
            .initial()
        }
    }

    @Test func parallelLayoutsRender() async {
        let store = MachineStore(Editor())
        // Two regions both reach their `off` initial → two active leaves named "off".
        await waitUntil { store.configuration?.activeLeaves.count == 2 }

        for layout in [MachineLayout.zStack, .vStack, .hStack, .tabs] {
            let view = MachineView(store, layout: layout) { state, _ in
                Text(state.name).frame(width: 80, height: 60)
            }
            #expect(ImageRenderer(content: view).cgImage != nil)
        }
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
