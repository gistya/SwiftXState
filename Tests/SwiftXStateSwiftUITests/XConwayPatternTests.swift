#if SWIFTXSTATE_APPLE_UI
import Testing
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

/// Mirrors the exact shape XConway's migrated `LifeMachine` / `LifeSession` rely on — a single-state
/// machine, a struct-payload `EventID`, a case-path `on:` for that struct payload, payloadless pure
/// actions, and the `MachineStore` + `await actor.send/context` drive — so the (unbuildable-here)
/// Xcode app's typed patterns are verified in the package.
@MainActor
@Suite("XConway migration patterns (Life-shaped machine)")
struct XConwayPatternTests {
    // A LifeContext-shaped value: a struct that must be Hashable to ride in an EventID payload.
    struct MiniGrid: Sendable, Equatable, Hashable {
        var cells: [Bool]
        var generation: Int = 0
        static var empty: MiniGrid { .init(cells: Array(repeating: false, count: 4)) }
    }

    enum MiniState: String, StateIdentifying { case running; static var _blank: MiniState { .running } }

    // The LifeEvent-shaped union: payloadless + scalar-payload + struct-payload (.restore) cases.
    enum MiniEvent: EventIdentifying {
        case toggle(i: Int)
        case step
        case restore(MiniGrid)
        static var _blank: MiniEvent { .step }
    }

    struct MiniLife: StateMachine {
        typealias Context = MiniGrid
        typealias StateID = MiniState
        typealias EventID = MiniEvent
        var context: MiniGrid { .empty }
        var machine: some XStateMachine {
            XState(.running) {
                XTransition(on: MiniEvent.toggle, to: .running).action { args, _ in
                    var c = args.context
                    if case let .toggle(i)? = args.event { c.cells[i].toggle() }
                    return c
                }
                XTransition(on: MiniEvent.restore, to: .running).action { args, _ in
                    if case let .restore(saved)? = args.event { return saved }
                    return args.context
                }
                XTransition(on: .step, to: .running).action { ctx in
                    var c = ctx
                    c.cells = c.cells.map { !$0 }   // trivial "next generation"
                    c.generation += 1
                    return c
                }
            }
            .initial()
        }
    }

    @Test func machineStoreDrivesLifeShapedMachine() async {
        let life = MachineStore(MiniLife())
        await waitUntil { life.configuration == .atomic(.running) }
        #expect(life.context.cells == [false, false, false, false])

        life.send(.toggle(i: 1))
        await waitUntil { life.context.cells[1] }
        #expect(life.context.cells == [false, true, false, false])

        life.send(.step)
        await waitUntil { life.context.generation == 1 }
        #expect(life.context.cells == [true, false, true, true])   // all flipped
    }

    @Test func awaitSendContextAndStructPayloadRestore() async {
        // The exact LifeSession idiom: await the typed send, read the typed context back, and restore
        // from a struct payload (.restore) carried through the engine.
        let life = MachineStore(MiniLife())
        await waitUntil { life.configuration != nil }

        let snapshot = MiniGrid(cells: [true, true, false, false], generation: 9)
        await life.actor.send(.restore(snapshot))
        let ctx = await life.actor.context
        #expect(ctx == snapshot)                       // struct payload round-tripped through the actor
        await waitUntil { life.context == snapshot }    // and reached the reactive store on main
    }
}
#endif
