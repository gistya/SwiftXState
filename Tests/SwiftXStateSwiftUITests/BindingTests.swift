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
@Suite("Plan D x SwiftUI — bind() (lens read / prism write)")
struct BindingTests {
    struct Settings: Sendable, Equatable {
        var volume: Double = 0.5
        var name: String = ""
    }
    enum Screen: String, StateIdentifying { case idle, playing; static var _blank: Screen { .idle } }
    enum Ev: EventIdentifying {
        case setVolume(Double)
        case setName(String)
        case play
        case pause
        static var _blank: Ev { .play }
    }

    struct Panel: StateMachine {
        typealias Context = Settings
        typealias StateID = Screen
        typealias EventID = Ev
        var context: Settings { .init() }
        var machine: some XStateMachine {
            XState(.idle) {
                XTransition(on: Ev.setVolume, to: .idle).action { args, _ in
                    var c = args.context
                    if case let .setVolume(v)? = args.event { c.volume = v }
                    return c
                }
                XTransition(on: Ev.setName, to: .idle).action { args, _ in
                    var c = args.context
                    if case let .setName(n)? = args.event { c.name = n }
                    return c
                }
                XTransition(on: .play, to: .playing)
            }.initial()
            XState(.playing) {
                XTransition(on: Ev.setVolume, to: .playing).action { args, _ in
                    var c = args.context
                    if case let .setVolume(v)? = args.event { c.volume = v }
                    return c
                }
                XTransition(on: .pause, to: .idle)
            }
        }
    }

    @Test func valueBindingReadsContextAndWritesEvent() async {
        let store = MachineStore(Panel())
        await waitUntil { store.configuration != nil }

        let volume = store.bind(\.volume, send: Ev.setVolume)
        let name = store.bind(\.name, send: Ev.setName)

        // Read = lens into context.
        #expect(volume.wrappedValue == 0.5)
        #expect(name.wrappedValue == "")

        // Write = send the event (the prism), which flows back to context.
        volume.wrappedValue = 0.8
        await waitUntil { store.context.volume == 0.8 }
        #expect(volume.wrappedValue == 0.8)

        name.wrappedValue = "Ada"
        await waitUntil { store.context.name == "Ada" }
        #expect(name.wrappedValue == "Ada")
    }

    @Test func stateBindingTogglesViaEvents() async {
        let store = MachineStore(Panel())
        await waitUntil { store.configuration != nil }

        let playing = store.bind(.playing, on: .play, off: .pause)
        #expect(playing.wrappedValue == false)

        playing.wrappedValue = true          // toggled on → send .play
        await waitUntil { store.matches(.playing) }
        #expect(playing.wrappedValue == true)

        playing.wrappedValue = false         // toggled off → send .pause
        await waitUntil { store.matches(.idle) }
        #expect(playing.wrappedValue == false)
    }
}
#endif
