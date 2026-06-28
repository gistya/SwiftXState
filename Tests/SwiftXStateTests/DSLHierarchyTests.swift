import Testing
@testable import SwiftXState

@Suite("Plan D — hierarchy & parallel (compound / parallel states)")
struct DSLHierarchyTests {
    // MARK: Compound

    enum Light: String, StateIdentifying {
        case green, yellow, red, walk, wait, stop
        static var _blank: Light { .green }
    }
    enum LightEvent: String, EventIdentifying {
        case timer, powerOutage, restore
        static var _blank: LightEvent { .timer }
    }

    /// `red` is a compound state with its own transition (`powerOutage`) plus a pedestrian sub-chart
    /// (walk → wait → stop).
    struct Crossing: StateMachine {
        typealias Context = Int
        typealias StateID = Light
        typealias EventID = LightEvent
        var context: Int { 0 }
        var machine: some XStateMachine {
            XState(.green)  { XTransition(on: .timer, to: .yellow) }.initial()
            XState(.yellow) { XTransition(on: .timer, to: .red) }
            XState(.red) {
                XTransition(on: .timer, to: .green)
                XState(.walk) { XTransition(on: .timer, to: .wait) }.initial()
                XState(.wait) { XTransition(on: .timer, to: .stop) }
                XState(.stop) {}
            }
        }
    }

    @Test func compoundSchemaIsNested() {
        let schema = Crossing().buildSchema()
        let red = schema.states[.red]
        #expect(red?.nodeType == .compound)
        #expect(red?.initialChild == .walk)
        #expect(red?.children.map(\.id) == [.walk, .wait, .stop])
        #expect(red?.transitions.first?.event == .timer)        // compound keeps its own `on`
        #expect(schema.states[.green]?.nodeType == .atomic)
    }

    @Test func compoundEntersInitialChild() async {
        let m = createActor(Crossing())
        await m.start()
        await m.send(.timer)  // green → yellow
        let atRed = await m.send(.timer)  // yellow → red, which enters red.walk
        // Active configuration is the nested tree: red ▸ walk.
        #expect(atRed?.activeLeaves == [.walk])
        #expect(atRed?.matches(.red) == true)             // compound parent is active
        #expect(atRed?.matches(path: "red.walk") == true) // and its initial child
    }

    @Test func nestedChildTransitionAdvances() async {
        let m = createActor(Crossing())
        await m.start()
        await m.send(.timer)            // → yellow
        await m.send(.timer)            // → red (walk)
        let afterTimer = await m.send(.timer)  // red.walk --timer--> red.wait
        #expect(afterTimer?.activeLeaves == [.wait])
        #expect(afterTimer?.matches(path: "red.wait") == true)
    }

    @Test func compoundOwnTransitionExitsWholeSubtree() async {
        // The compound's own `on: timer → green` competes with the child's `timer`. The child's
        // transition is more deeply nested, so it wins (XState selects the innermost handler).
        // After walk → wait → stop, `stop` has no `timer`, so the parent's `timer → green` fires.
        let m = createActor(Crossing())
        await m.start()
        await m.send(.timer); await m.send(.timer)  // → red.walk
        await m.send(.timer)                         // → red.wait
        await m.send(.timer)                         // → red.stop
        #expect(await m.matches(path: "red.stop"))
        let out = await m.send(.timer)               // stop has no timer → parent timer → green
        #expect(out == .atomic(.green))
    }

    // MARK: Parallel

    enum Format: String, StateIdentifying {
        case editing, bold, underline, on, off
        static var _blank: Format { .editing }
    }
    enum FormatEvent: String, EventIdentifying {
        case toggleBold, toggleUnderline
        static var _blank: FormatEvent { .toggleBold }
    }

    /// `editing` is a parallel state with two independent regions (bold, underline), each a small
    /// on/off compound.
    struct Editor: StateMachine {
        typealias Context = Int
        typealias StateID = Format
        typealias EventID = FormatEvent
        var context: Int { 0 }
        var machine: some XStateMachine {
            XState(.editing) {
                XState(.bold) {
                    XState(.off) { XTransition(on: .toggleBold, to: .on) }.initial()
                    XState(.on)  { XTransition(on: .toggleBold, to: .off) }
                }
                XState(.underline) {
                    XState(.off) { XTransition(on: .toggleUnderline, to: .on) }.initial()
                    XState(.on)  { XTransition(on: .toggleUnderline, to: .off) }
                }
            }
            .parallel()
            .initial()
        }
    }

    @Test func parallelSchemaHasRegions() {
        let schema = Editor().buildSchema()
        let editing = schema.states[.editing]
        #expect(editing?.nodeType == .parallel)
        #expect(editing?.children.map(\.id) == [.bold, .underline])
        #expect(editing?.children.first?.nodeType == .compound)   // each region is a compound
        #expect(editing?.children.first?.initialChild == .off)
    }

    @Test func parallelRegionsAreSimultaneouslyActive() async {
        let m = createActor(Editor())
        let initial = await m.start()
        // Both regions active at once, each in its `off` initial.
        #expect(initial?.matches(path: "editing.bold.off") == true)
        #expect(initial?.matches(path: "editing.underline.off") == true)
    }

    @Test func parallelRegionsToggleIndependently() async {
        let m = createActor(Editor())
        await m.start()
        let afterBold = await m.send(.toggleBold)
        // bold flips to on; underline stays off — independence.
        #expect(afterBold?.matches(path: "editing.bold.on") == true)
        #expect(afterBold?.matches(path: "editing.underline.off") == true)

        let afterUnderline = await m.send(.toggleUnderline)
        #expect(afterUnderline?.matches(path: "editing.bold.on") == true)        // unchanged
        #expect(afterUnderline?.matches(path: "editing.underline.on") == true)   // now both on
    }
}
