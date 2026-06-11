//
//  WinC.swift
//  SwiftXState
//
//  Exposes the `@WinC` macro used by the Windows / C# bridge (SwiftXStateWinBridge).
//

/// Exports a global function to C — and therefore to C# — when the Windows bridge is being built.
///
/// `@WinC` is active only when the `SWIFTXWIN` environment variable is set at build time. When it is,
/// the macro generates a peer `@_cdecl("FunctionName")` function (the original name with its first
/// letter capitalized) that forwards to the annotated function, producing a stable C symbol. When the
/// variable is unset the macro expands to nothing, so normal Apple/Linux/wasm builds carry no extra
/// symbols and pay no cost.
///
/// Apply it to plain global functions — not `async`, not `throws`, not generic — whose parameters and
/// return type are C-compatible: integers, `UnsafePointer<CChar>` strings, opaque pointers, and the
/// like. The macro forwards the call unchanged, so the compiler enforces C-compatibility on the
/// generated export.
///
/// ```swift
/// @WinC public func addNumbers(_ a: Int32, _ b: Int32) -> Int32 { a + b }
/// // With SWIFTXWIN set, also emits:
/// //   @_cdecl("AddNumbers") public func AddNumbers(_ a: Int32, _ b: Int32) -> Int32 { addNumbers(a, b) }
/// ```
@attached(peer, names: suffixed(_WinC))
public macro WinC() = #externalMacro(module: "SwiftXStateMacros", type: "WinCMacro")
