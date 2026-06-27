import Testing
@testable import SwiftXState

@Suite("Plan D — typed identity foundation")
struct DSLIdentityTests {
    // RawRepresentable enum → `name` is the raw value.
    enum LightState: String, StateIdentifying {
        case red, green, yellow
        static var _blank: LightState { .red }
    }

    // Plain enum (no raw value) → `name` is the case name.
    enum LightEvent: EventIdentifying {
        case go, caution, stop
        static var _blank: LightEvent { .stop }
    }

    // The whole point: a schema identity is just the three associated families.
    struct TrafficSchema: MachineSchemable {
        typealias Context = Int
        typealias StateID = LightState
        typealias EventID = LightEvent
    }

    @Test func rawRepresentableName() {
        #expect(LightState.green.name == "green")
        #expect(LightState.red.name == "red")
    }

    @Test func caseName() {
        #expect(LightEvent.caution.name == "caution")
    }

    @Test func identifiersAreHashableKeys() {
        var seen: [LightState: Int] = [:]
        for (i, s) in [LightState.red, .green, .yellow].enumerated() { seen[s] = i }
        #expect(seen[.green] == 1)
    }

    // String is the (unsafe) instantiation — usable as both a state id and an event id.
    @Test func stringInstantiation() {
        let s: any StateIdentifying = "idle"
        let e: any EventIdentifying = "GO"
        #expect(s.name == "idle")
        #expect(e.name == "GO")
        #expect(String._blank == "")
    }

    @Test func stringSchemaIsValid() {
        struct StringSchema: MachineSchemable {
            typealias Context = Int
            typealias StateID = String
            typealias EventID = String
        }
        #expect(StringSchema.StateID.self == String.self)
    }
}
