import XCTest
import SwiftSyntaxMacros
import SwiftSyntaxMacrosTestSupport
import SwiftXStateMacros

private let macros: [String: Macro.Type] = ["WinC": WinCMacro.self]

final class WinCMacroTests: XCTestCase {

    /// @WinC emits an `#if SWIFTXWIN`-wrapped peer `@_cdecl` export, named with the original's first
    /// letter capitalized, forwarding to the original. The `#if` keys off the `-D SWIFTXWIN` define
    /// that Package.swift adds when the SWIFTXWIN env var is set — gating can't be done in the macro,
    /// because SwiftPM doesn't pass the build environment to macro plugins.
    func testEmitsGuardedCdeclPeer() {
        assertMacroExpansion(
            """
            @WinC
            public func addNumbers(_ a: Int32, _ b: Int32) -> Int32 {
                a + b
            }
            """,
            expandedSource: """
            public func addNumbers(_ a: Int32, _ b: Int32) -> Int32 {
                a + b
            }

            #if SWIFTXWIN
            @_cdecl("AddNumbers")
            public func addNumbers_WinC(_ a: Int32, _ b: Int32) -> Int32 {
                return addNumbers(a, b)
            }
            #endif
            """,
            macros: macros
        )
    }
}
