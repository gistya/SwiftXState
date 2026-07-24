#if canImport(SwiftUI)
import SwiftUI
import Testing
@testable import SwiftXState

/// Proves the `StateMachine` member typealiases `State` / `Transition` (added for generic inference)
/// do NOT collide with `SwiftUI.State` / `SwiftUI.Transition`: they are protocol members, so they only
/// shadow *inside* a conforming type — a `View` in the very same file still binds `@State` /
/// `.transition(...)` to SwiftUI. If this file compiles, there is no global-namespace collision.
@Suite("SwiftUI name coexistence (State / Transition typealiases)")
struct SwiftUINameCoexistenceTests {
    enum S: String, StateIdentifying { case a, b; static var _blank: S { .a } }
    enum E: String, EventIdentifying { case go; static var _blank: E { .go } }

    // Bare `State` / `Transition` resolve to the machine's typealiases here (inside the conformer).
    struct M: StateMachine {
        typealias Context = Int
        typealias StateID = S
        typealias EventID = E
        var context: Int { 0 }
        var machine: some XStateMachine {
            State(.a) { Transition(on: .go, to: .b) }.initial()
            State(.b) {}
        }
    }

    // `@State` / `.transition` here bind to SwiftUI — the typealiases are not global.
    struct DemoView: View {
        @State private var count = 0
        var body: some View {
            Text("\(count)")
                .transition(.opacity)
        }
    }

    @Test func machineUsesTypealiasesWhileViewUsesSwiftUI() async {
        let actor = createActor(M())
        await actor.start()
        #expect(await actor.matches(.a))
        await actor.send(.go)
        #expect(await actor.matches(.b))
        _ = DemoView()   // constructs the SwiftUI view — compile-time proof of coexistence
    }
}
#endif
