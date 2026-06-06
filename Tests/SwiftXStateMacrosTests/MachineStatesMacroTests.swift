import XCTest
import SwiftSyntaxMacros
import SwiftSyntaxMacrosTestSupport
import SwiftXStateMacros

private let macros: [String: Macro.Type] = ["MachineStates": MachineStatesMacro.self]

final class MachineStatesMacroTests: XCTestCase {

    func testFlatStates() {
        assertMacroExpansion(
            """
            @MachineStates("LightsState")
            let config = MachineConfig(id: "lights", initial: "green", states: [
                "green": StateNodeConfig(),
                "yellow": StateNodeConfig(),
                "red": StateNodeConfig(),
            ])
            """,
            expandedSource: """
            let config = MachineConfig(id: "lights", initial: "green", states: [
                "green": StateNodeConfig(),
                "yellow": StateNodeConfig(),
                "red": StateNodeConfig(),
            ])

            enum LightsState: String, StateName {
                case green
                case yellow
                case red
            }
            """,
            macros: macros
        )
    }

    func testNestedStatesBecomeDotPathCases() {
        assertMacroExpansion(
            """
            @MachineStates("S")
            let config = MachineConfig(id: "m", initial: "active", states: [
                "active": StateNodeConfig(initial: "fast", states: [
                    "fast": StateNodeConfig(),
                    "slow": StateNodeConfig(),
                ]),
                "idle": StateNodeConfig(),
            ])
            """,
            expandedSource: """
            let config = MachineConfig(id: "m", initial: "active", states: [
                "active": StateNodeConfig(initial: "fast", states: [
                    "fast": StateNodeConfig(),
                    "slow": StateNodeConfig(),
                ]),
                "idle": StateNodeConfig(),
            ])

            enum S: String, StateName {
                case active
                case activeFast = "active.fast"
                case activeSlow = "active.slow"
                case idle
            }
            """,
            macros: macros
        )
    }

    func testSpacedStateNameSanitized() {
        assertMacroExpansion(
            """
            @MachineStates("S")
            let config = MachineConfig(id: "m", states: [
                "Checking if required": StateNodeConfig(),
            ])
            """,
            expandedSource: """
            let config = MachineConfig(id: "m", states: [
                "Checking if required": StateNodeConfig(),
            ])

            enum S: String, StateName {
                case checkingIfRequired = "Checking if required"
            }
            """,
            macros: macros
        )
    }
}
