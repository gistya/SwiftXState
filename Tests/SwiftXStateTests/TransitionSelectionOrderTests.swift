import Testing
@testable import SwiftXState

private struct SelectionContext: Sendable, Equatable, Codable {
    var takeGuarded: Bool
}

private func selectionMachine(takeGuarded: Bool) -> MachineConfig<SelectionContext> {
    MachineConfig(
        initial: "start",
        context: SelectionContext(takeGuarded: takeGuarded),
        states: [
            "start": StateNodeConfig(on: [
                "GO": .multiple([
                    TransitionConfig(target: "guarded", guard: .inline { $0.context.takeGuarded }),
                    TransitionConfig(target: "fallback"),
                ]),
            ]),
            "guarded": StateNodeConfig(),
            "fallback": StateNodeConfig(),
        ]
    )
}

/// XState semantics: for a given state node and event, the FIRST transition (in declaration order)
/// whose guard passes is taken — the rest are not. A guarded transition declared before a catch-all
/// must win when its guard holds; the catch-all is reached only when the earlier guard fails.
///
/// The previous implementation applied *every* enabled transition for the event, so a later
/// (guardless) catch-all overrode an earlier guarded one, and the outcome depended on hash-seeded
/// ordering — a determinism bug for a replay-focused engine.
@Suite("Transition selection order")
struct TransitionSelectionOrderTests {
    @Test("a guarded transition wins over a later catch-all on the same event")
    func guardedBeatsLaterCatchAll() {
        let machine = createMachine(selectionMachine(takeGuarded: true))
        let (initial, _) = SwiftXState.initialTransition(machine)
        let (next, _) = SwiftXState.transition(machine, snapshot: initial, event: Event("GO"))
        #expect(next.matches("guarded"))
        #expect(!next.matches("fallback"))
    }

    @Test("the catch-all is taken only when the earlier guard fails")
    func catchAllTakenWhenGuardFails() {
        let machine = createMachine(selectionMachine(takeGuarded: false))
        let (initial, _) = SwiftXState.initialTransition(machine)
        let (next, _) = SwiftXState.transition(machine, snapshot: initial, event: Event("GO"))
        #expect(next.matches("fallback"))
        #expect(!next.matches("guarded"))
    }
}
