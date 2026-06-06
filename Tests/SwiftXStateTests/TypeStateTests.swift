import Foundation
import Testing
@testable import SwiftXState

// A non-chess fixture exercising the TypeState-lite surface: a media player whose root is a
// parallel machine with a `mode` region (playing/paused/stopped) and a parallel `controls` region
// (shuffle + repeat, each off/on). Mirrors the structure the chess machine used (a game region +
// a parallel castling region) without the chess dependency.

private struct PlayerContext: Sendable, Equatable {}

/// Brand for the `mode` region.
private enum Mode: String, StateID, CaseIterable, Equatable {
    case playing = "mode.playing"
    case paused = "mode.paused"
    case stopped = "mode.stopped"
}

private enum Control: String, Sendable, CaseIterable { case shuffle, repeatMode }
private enum Switch: String, Sendable { case off, on }

/// Brand for the parallel `controls` region (region root + nested per-control sub-states).
private enum Controls: StateID, Equatable {
    case region
    case control(Control, Switch)

    var statePath: String {
        switch self {
        case .region: return "controls"
        case let .control(control, value): return "controls.\(control.rawValue).\(value.rawValue)"
        }
    }
}

/// Custom branded accessor — the generic analogue of the chess `gamePhase` convenience.
private extension TypedSnapshot where Brand == Mode {
    var phase: Mode? { Mode.allCases.first { inState($0) } }
}

/// Domain helper built over the typed parallel region (analogue of `availability(for:)`).
private extension TypedSnapshot where Brand == Controls {
    func value(for control: Control) -> Switch {
        inState(.control(control, .on)) ? .on : .off
    }
}

/// A domain value reconstructed from a raw `StateValue` via typed paths (analogue of
/// `CastlingRights(stateValue:)`).
private struct ControlStates: Equatable {
    var shuffle: Bool
    var repeatOn: Bool

    static let allOff = ControlStates(shuffle: false, repeatOn: false)

    init(shuffle: Bool, repeatOn: Bool) {
        self.shuffle = shuffle
        self.repeatOn = repeatOn
    }

    init(stateValue: StateValue) {
        shuffle = stateValue.matches(Controls.control(.shuffle, .on))
        repeatOn = stateValue.matches(Controls.control(.repeatMode, .on))
    }
}

private func makePlayer() -> StateMachine<PlayerContext> {
    createMachine(MachineConfig(
        context: PlayerContext(),
        states: [
            "mode": StateNodeConfig(
                initial: "playing",
                states: [
                    "playing": StateNodeConfig(on: ["PAUSE": .to("paused"), "STOP": .to("stopped")]),
                    "paused": StateNodeConfig(on: ["PLAY": .to("playing"), "STOP": .to("stopped")]),
                    "stopped": StateNodeConfig(type: .atomic),
                ]
            ),
            "controls": StateNodeConfig(
                type: .parallel,
                states: [
                    "shuffle": StateNodeConfig(
                        initial: "off",
                        states: [
                            "off": StateNodeConfig(on: ["SHUFFLE": .to("on")]),
                            "on": StateNodeConfig(on: ["SHUFFLE": .to("off")]),
                        ]
                    ),
                    "repeatMode": StateNodeConfig(
                        initial: "off",
                        states: [
                            "off": StateNodeConfig(on: ["REPEAT": .to("on")]),
                            "on": StateNodeConfig(on: ["REPEAT": .to("off")]),
                        ]
                    ),
                ]
            ),
        ],
        type: .parallel
    ))
}

@Suite("TypeState-lite")
struct TypeStateTests {
    @Test("TypedSnapshot matches StateID paths")
    func typedSnapshotMatches() {
        let actor = createActor(makePlayer()).start()
        let typed = actor.snapshot.typed(as: Mode.self)

        #expect(typed.inState(.playing))
        #expect(typed.matches(Mode.playing))
        #expect(typed.phase == .playing)
        #expect(!typed.inState(.stopped))
    }

    @Test("TypedActor send returns branded snapshot")
    func typedActorSend() {
        let player = createActor(makePlayer()).typed(as: Mode.self)

        #expect(player.start().inState(Mode.playing))

        let paused = player.send(Event("PAUSE"))
        #expect(paused.inState(Mode.paused))
        #expect(paused.phase == .paused)
    }

    @Test("MachineSnapshot matches StateID overload")
    func snapshotStateIDOverload() {
        let snapshot = createActor(makePlayer()).start().snapshot
        #expect(snapshot.matches(Mode.playing))
        #expect(!snapshot.matches(Mode.stopped))
    }

    @Test("narrowed returns nil when state does not match")
    func narrowedFiltering() {
        let typed = createActor(makePlayer()).start().snapshot.typed(as: Mode.self)

        #expect(typed.narrowed(to: .playing) != nil)
        #expect(typed.narrowed(to: .stopped) == nil)
    }

    @Test("parallel region starts with all controls off")
    func controlsInitialState() {
        let controls = createActor(makePlayer()).start().snapshot.typed(as: Controls.self)

        #expect(controls.inState(.region))
        for control in Control.allCases {
            #expect(controls.value(for: control) == .off)
            #expect(controls.inState(.control(control, .off)))
        }
        #expect(ControlStates(stateValue: controls.value) == .allOff)
    }

    @Test("toggling one control leaves the sibling parallel region untouched")
    func controlsToggleIndependently() {
        let actor = createActor(makePlayer()).start()
        actor.send(Event("SHUFFLE"))

        let controls = actor.snapshot.typed(as: Controls.self)
        #expect(controls.value(for: .shuffle) == .on)
        #expect(controls.value(for: .repeatMode) == .off)
        #expect(controls.inState(.control(.shuffle, .on)))
        #expect(controls.inState(.control(.repeatMode, .off)))
    }

    @Test("domain value reconstructs from StateValue via typed paths")
    func controlStatesFromStateValue() {
        let actor = createActor(makePlayer()).start()
        #expect(ControlStates(stateValue: actor.snapshot.value) == .allOff)

        actor.send(Event("REPEAT"))
        #expect(ControlStates(stateValue: actor.snapshot.value) == ControlStates(shuffle: false, repeatOn: true))
    }
}
