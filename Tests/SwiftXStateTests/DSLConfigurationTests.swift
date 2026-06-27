import Testing
@testable import SwiftXState

@Suite("Plan D — typed Configuration")
struct DSLConfigurationTests {
    enum S: String, StateIdentifying {
        case working, crossing, red, green, yellow, pedestrian, signal, walk, wait, flash, solid
        static var _blank: S { .red }
    }

    typealias Config = Configuration<S>

    // flat: the active position is one leaf
    @Test func flatAtomic() {
        let c: Config = .atomic(.green)
        #expect(c.matches(.green))
        #expect(!c.matches(.red))
        #expect(c.activeLeaves == [.green])
        #expect(c.description == "green")
    }

    // compound: in `working`, whose active substate is `red`
    @Test func compoundMatch() {
        let c: Config = .nested([.working: .atomic(.red)])
        #expect(c.matches(.working))               // the compound is active
        #expect(!c.matches(.red))                  // not at this level — use a path
        #expect(c.matches(path: "working.red"))
        #expect(!c.matches(path: "working.green"))
        #expect(c.activeLeaves == [.red])
    }

    // parallel: in `crossing`, with both regions active simultaneously
    @Test func parallelSubsetMatch() {
        let c: Config = .nested([
            .crossing: .nested([
                .pedestrian: .atomic(.walk),
                .signal: .atomic(.flash),
            ])
        ])
        // a partial target naming only one region still matches (subset/refinement)
        #expect(c.matches(.nested([.crossing: .nested([.pedestrian: .atomic(.walk)])])))
        // both regions present
        #expect(c.matches(path: "crossing.pedestrian.walk"))
        #expect(c.matches(path: "crossing.signal.flash"))
        // wrong region value fails
        #expect(!c.matches(path: "crossing.signal.solid"))
        #expect(c.activeLeaves == [.walk, .flash])
    }

    // Configuration<String> behaves like the engine's StateValue (the string instantiation)
    @Test func stringInstantiation() {
        let c: Configuration<String> = .nested(["light": .atomic("red")])
        #expect(c.matches("light"))
        #expect(c.matches(path: "light.red"))
        #expect(c.activeLeaves == ["red"])
    }
}
