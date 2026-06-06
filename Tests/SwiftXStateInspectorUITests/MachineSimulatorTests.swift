#if SWIFTXSTATE_INSPECTOR_UI
import Testing
@testable import SwiftXState
@testable import SwiftXStateInspectorUI

@Suite("Machine simulator (structural stepping)")
struct MachineSimulatorTests {

    private func sim(_ json: String, id: String = "m") -> MachineSimulator {
        MachineSimulator(definitionJSON: json, machineID: id)!
    }

    @Test("flat machine: sibling transitions cycle through states")
    func flatSiblings() {
        let s = sim("""
        { "id": "m", "initial": "green",
          "states": {
            "green": { "on": { "NEXT": "yellow" } },
            "yellow": { "on": { "NEXT": "red" } },
            "red": { "on": { "NEXT": "green" } }
          } }
        """)
        var v = s.initialValue()
        #expect(v == .atomic("green"))
        #expect(s.availableEvents(from: v) == ["NEXT"])
        v = s.step(from: v, event: "NEXT")!
        #expect(v == .atomic("yellow"))
        v = s.step(from: v, event: "NEXT")!
        #expect(v == .atomic("red"))
        v = s.step(from: v, event: "NEXT")!
        #expect(v == .atomic("green"))
    }

    @Test("unknown event from a state yields nil")
    func unknownEvent() {
        let s = sim("""
        { "id": "m", "initial": "a", "states": { "a": { "on": { "GO": "b" } }, "b": {} } }
        """)
        #expect(s.step(from: .atomic("a"), event: "NOPE") == nil)
        #expect(s.step(from: .atomic("b"), event: "GO") == nil) // b is a dead end
    }

    @Test("compound: entering a parent descends to its initial child")
    func compoundDescent() {
        let s = sim("""
        { "id": "m", "initial": "idle",
          "states": {
            "idle": { "on": { "START": "running" } },
            "running": {
              "initial": "fast",
              "states": { "fast": { "on": { "SLOW": "slow" } }, "slow": {} },
              "on": { "STOP": "idle" }
            }
          } }
        """)
        var v = s.initialValue()
        #expect(v == .atomic("idle"))
        v = s.step(from: v, event: "START")!
        #expect(v == .compound(["running": .atomic("fast")]))   // descended to initial child
        // inner transition stays within running
        v = s.step(from: v, event: "SLOW")!
        #expect(v == .compound(["running": .atomic("slow")]))
        // ancestor handler (STOP on running) is available from the inner child
        #expect(s.availableEvents(from: v).contains("STOP"))
        v = s.step(from: v, event: "STOP")!
        #expect(v == .atomic("idle"))
    }

    @Test("parallel: each region advances independently")
    func parallelRegions() {
        let s = sim("""
        { "id": "fmt", "type": "parallel",
          "states": {
            "bold": { "initial": "off",
              "states": { "off": { "on": { "TB": "on" } }, "on": { "on": { "TB": "off" } } } },
            "italic": { "initial": "off",
              "states": { "off": { "on": { "TI": "on" } }, "on": { "on": { "TI": "off" } } } }
          } }
        """, id: "fmt")
        var v = s.initialValue()
        #expect(v == .compound(["bold": .atomic("off"), "italic": .atomic("off")]))
        #expect(s.availableEvents(from: v) == ["TB", "TI"])
        // Toggling bold leaves italic untouched.
        v = s.step(from: v, event: "TB")!
        #expect(v == .compound(["bold": .atomic("on"), "italic": .atomic("off")]))
        v = s.step(from: v, event: "TI")!
        #expect(v == .compound(["bold": .atomic("on"), "italic": .atomic("on")]))
    }

    @Test("always / after / invoke.onDone surface as drivable synthetic events")
    func syntheticTransitions() {
        let s = sim("""
        {
          "id": "Search as you type", "initial": "Inactive",
          "states": {
            "Inactive": { "on": { "input.focus": { "target": "Active" } } },
            "Active": {
              "initial": "Checking if initial fetching is required",
              "states": {
                "Checking if initial fetching is required": {
                  "always": [
                    { "guard": "Has search query been fetched", "target": "Idle" },
                    { "target": "Fetching" }
                  ]
                },
                "Idle": {},
                "Debouncing": { "after": { "500": { "target": "Fetching" } } },
                "Fetching": { "invoke": { "src": "Autocomplete search", "onDone": { "target": "Idle" } } }
              },
              "on": {
                "input.change": { "target": "Debouncing" },
                "combobox.click-outside": { "target": "Inactive" }
              }
            }
          }
        }
        """, id: "Search as you type")

        var v = s.initialValue()
        #expect(v == .atomic("Inactive"))

        // input.focus -> Active, descending to its initial child.
        v = s.step(from: v, event: "input.focus")!
        #expect(v == .compound(["Active": .atomic("Checking if initial fetching is required")]))

        // Both `always` branches are offered as buttons (we can't evaluate the guard).
        let checkingEvents = s.availableEvents(from: v)
        #expect(checkingEvents.contains("always → Idle"))
        #expect(checkingEvents.contains("always → Fetching"))
        #expect(checkingEvents.contains("input.change")) // ancestor event still available

        // Take the eventless branch into Fetching.
        v = s.step(from: v, event: "always → Fetching")!
        #expect(v == .compound(["Active": .atomic("Fetching")]))

        // invoke.onDone is drivable.
        #expect(s.availableEvents(from: v).contains("onDone"))
        v = s.step(from: v, event: "onDone")!
        #expect(v == .compound(["Active": .atomic("Idle")]))

        // input.change -> Debouncing, whose `after` delay is drivable.
        v = s.step(from: v, event: "input.change")!
        #expect(v == .compound(["Active": .atomic("Debouncing")]))
        #expect(s.availableEvents(from: v).contains("after 500ms"))
        v = s.step(from: v, event: "after 500ms")!
        #expect(v == .compound(["Active": .atomic("Fetching")]))

        // And we can leave the whole subtree.
        v = s.step(from: v, event: "combobox.click-outside")!
        #expect(v == .atomic("Inactive"))
    }

    @Test("absolute #id targets resolve")
    func absoluteTarget() {
        let s = sim("""
        { "id": "m", "initial": "a",
          "states": {
            "a": { "on": { "JUMP": "#deep" } },
            "b": { "initial": "inner", "states": { "inner": { "id": "deep" } } }
          } }
        """)
        let v = s.step(from: .atomic("a"), event: "JUMP")!
        #expect(v == .compound(["b": .atomic("inner")]))
    }
}

@Suite("Inspector store: structural send")
struct InspectorSendTests {

    @Test("loaded machine is simulatable; send advances state + appends feed")
    @MainActor
    func sendAdvances() throws {
        let store = InspectorStore()
        try store.loadDefinition(json: """
        { "id": "lights", "initial": "green",
          "states": {
            "green": { "on": { "NEXT": "yellow" } },
            "yellow": { "on": { "NEXT": "red" } },
            "red": { "on": { "NEXT": "green" } }
          } }
        """)
        #expect(store.isSimulatable("lights"))
        #expect(store.availableEvents(for: "lights") == ["NEXT"])
        #expect(store.selectedActor?.stateValue == .atomic("green"))

        let feedBefore = store.feed.count
        store.send("NEXT", to: "lights")
        #expect(store.selectedActor?.stateValue == .atomic("yellow"))
        #expect(store.selectedActor?.lastEventType == "NEXT")
        #expect(store.feed.count == feedBefore + 2) // event + snapshot rows
    }

    @Test("live (non-loaded) actors are not simulatable")
    @MainActor
    func liveNotSimulatable() {
        let store = InspectorStore()
        let ref = InspectionActorRef(sessionId: "live", machineId: "live")
        store.ingest(InspectionEvent(kind: .actor, rootId: "live", actor: ref))
        #expect(!store.isSimulatable("live"))
        #expect(store.availableEvents(for: "live").isEmpty)
        store.send("ANYTHING", to: "live") // no-op
        #expect(store.feed.count == 1)
    }
}
#endif
