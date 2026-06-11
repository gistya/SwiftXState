//
//  WinBridge.swift
//  SwiftXState
//
//  The Windows / C# bridge. Each `@WinC` function below becomes a C export (with its name
//  capitalized) when the package is built with the SWIFTXWIN environment variable set; on every other
//  build the macro expands to nothing and these are just ordinary Swift functions.
//
//  Signatures must be C-compatible — integers, C strings (`UnsafePointer<CChar>` in,
//  `UnsafeMutablePointer<CChar>` out via `strdup`), and opaque handles. Strings returned to C are
//  heap-allocated; the C# side frees them (see Interop/csharp/SwiftXStateWinBridge.cs). The matching
//  C# P/Invoke wrappers must be kept in step with these declarations.
//

import Foundation
import SwiftXState
// SwiftXStateInspect is linked too; inspect-backed exports (live snapshots, definition import) go here.

/// SwiftXState version string. The caller owns the returned C string and must free it.
@WinC
public func swiftXStateVersion() -> UnsafeMutablePointer<CChar>? {
    strdup("SwiftXState (Windows bridge)")
}

/// Minimal numeric export — the smoke test for the C ABI round-trip.
@WinC
public func addNumbers(_ a: Int32, _ b: Int32) -> Int32 {
    a + b
}

/// Proves SwiftXState itself is reachable across the bridge: builds a small machine and returns its
/// Stately-compatible definition JSON as a C string (caller frees). Real, handle-based actor/event
/// APIs will follow the same C-string + opaque-handle conventions.
@WinC
public func sampleDefinitionJSON() -> UnsafeMutablePointer<CChar>? {
    let machine = createMachine(MachineConfig(
        id: "toggle",
        initial: "off",
        context: EmptyContext(),
        states: [
            "off": StateNodeConfig(on: ["TOGGLE": .to("on")]),
            "on": StateNodeConfig(on: ["TOGGLE": .to("off")]),
        ]
    ))
    let json = (try? machine.definitionJSON()) ?? "{}"
    return strdup(json)
}
