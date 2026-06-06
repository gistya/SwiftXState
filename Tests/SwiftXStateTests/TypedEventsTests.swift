import Testing
@testable import SwiftXState

// Typed events — each is its own type (Tier 2), with explicit XState-style `eventType` strings.
private struct InputChange: StateEvent, Equatable { static let eventType = "input.change"; let searchInput: String }
private struct ItemClick: StateEvent, Equatable { static let eventType = "item.click"; let itemId: Int }
private struct Focus: StateEvent, Equatable { static let eventType = "input.focus" }

private struct SearchCtx: Sendable, Equatable {
    var searchInput = ""
    var picked = ""
    var items = ["alpha", "beta", "gamma"]
}

@Suite("Tier 2: typed events with per-event narrowing")
struct TypedEventsTests {

    private func machine() -> StateMachine<SearchCtx> {
        createMachine(MachineConfig(
            id: "search", initial: "inactive", context: SearchCtx(),
            states: [
                "inactive": StateNodeConfig(on: transitions(
                    on(Focus.self, target: "active")
                )),
                "active": StateNodeConfig(on: transitions(
                    // Guard + action both receive the *concrete* event — no cast, no assertEvent.
                    on(InputChange.self, target: "active", reenter: true,
                       actions: [assign { (c: inout SearchCtx, e: InputChange) in c.searchInput = e.searchInput }]),
                    on(ItemClick.self, target: "inactive",
                       actions: [assign { (c: inout SearchCtx, e: ItemClick) in c.picked = c.items[e.itemId] }])
                )),
            ]
        ))
    }

    @Test("typed action narrows the event and updates context")
    func typedActionNarrows() {
        let actor = createActor(machine()).start()
        actor.send(Focus())
        #expect(actor.snapshot.matches("active"))

        actor.send(InputChange(searchInput: "be"))
        #expect(actor.snapshot.context.searchInput == "be")   // narrowed payload applied

        actor.send(ItemClick(itemId: 1))
        #expect(actor.snapshot.context.picked == "beta")      // c.items[e.itemId]
        #expect(actor.snapshot.matches("inactive"))
    }

    @Test("typed guard narrows the event to decide the branch")
    func typedGuardNarrows() {
        // Only accept a click on a valid index; otherwise stay put.
        let m = createMachine(MachineConfig(
            id: "g", initial: "idle", context: SearchCtx(),
            states: [
                "idle": StateNodeConfig(on: transitions(
                    on(ItemClick.self, target: "picked",
                       guard: guarded { (c: SearchCtx, e: ItemClick) in e.itemId >= 0 && e.itemId < c.items.count })
                )),
                "picked": StateNodeConfig(),
            ]
        ))
        let actor = createActor(m).start()
        actor.send(ItemClick(itemId: 99))     // out of range -> guard false -> no transition
        #expect(actor.snapshot.matches("idle"))
        actor.send(ItemClick(itemId: 0))      // valid -> transition
        #expect(actor.snapshot.matches("picked"))
    }

    @Test("typed send only accepts StateEvents but works exactly like Tier 1")
    func typedSend() {
        let actor = createActor(machine()).start()
        actor.send(Focus())                    // typed value; send<E: Eventable> accepts it directly
        #expect(actor.snapshot.matches("active"))
    }

    @Test("Tier 2 compiles down to the same definition JSON as Tier 1")
    func sameExportAsTier1() throws {
        // Tier 1, hand-written with string keys.
        let tier1 = createMachine(MachineConfig(
            id: "x", initial: "a", context: SearchCtx(),
            states: [
                "a": StateNodeConfig(on: ["input.focus": .to("b")]),
                "b": StateNodeConfig(),
            ]
        ))
        // Tier 2, same machine via typed events.
        let tier2 = createMachine(MachineConfig(
            id: "x", initial: "a", context: SearchCtx(),
            states: [
                "a": StateNodeConfig(on: transitions(on(Focus.self, target: "b"))),
                "b": StateNodeConfig(),
            ]
        ))
        #expect(try tier1.definitionJSON() == tier2.definitionJSON())
    }

    @Test("default eventType derives from the type name")
    func defaultEventType() {
        struct Ping: StateEvent {}
        #expect(Ping.eventType == "Ping")
        #expect(Ping().type == "Ping")
        #expect(InputChange.eventType == "input.change")
    }
}
