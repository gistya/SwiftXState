import Foundation
import SwiftSyntax
import SwiftSyntaxMacros

/// Errors surfaced at the `@WinC` attribution site (only when the bridge is actually being built).
enum WinCError: Error, CustomStringConvertible {
    case onlyGlobalFunctions
    case noEffects
    case noGenerics
    var description: String {
        switch self {
        case .onlyGlobalFunctions:
            return "@WinC can only be applied to a global function — it generates a peer @_cdecl C export, "
                 + "and @_cdecl is not valid on methods, properties, or types."
        case .noEffects:
            return "@WinC functions can't be 'async' or 'throws'; a @_cdecl export must be a plain C function."
        case .noGenerics:
            return "@WinC functions can't be generic; a @_cdecl export must have a concrete C signature."
        }
    }
}

/// Implementation of `@WinC`. When the package is built with the `SWIFTXWIN` environment variable set,
/// it emits a peer `@_cdecl("CapitalizedName")` function that forwards to the annotated function,
/// giving a stable C symbol for the Windows / C# bridge. With the variable unset it emits nothing, so
/// ordinary builds carry no extra symbols.
///
/// The annotated function must be a plain global function whose parameters and return type are
/// C-compatible (integers, `UnsafePointer<CChar>` strings, opaque pointers, …); the macro forwards the
/// call unchanged, so the compiler enforces C-compatibility on the generated `@_cdecl` function.
public struct WinCMacro: PeerMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        // The peer is always generated, but wrapped in `#if SWIFTXWIN` so it only compiles when the
        // Windows bridge is being built. Gating can't be done by reading the environment here —
        // SwiftPM doesn't pass the build environment to macro plugin processes — so Package.swift adds
        // `-D SWIFTXWIN` (driven by the SWIFTXWIN env var) and this `#if` keys off that.
        guard let fn = declaration.as(FunctionDeclSyntax.self) else { throw WinCError.onlyGlobalFunctions }
        if fn.signature.effectSpecifiers != nil { throw WinCError.noEffects }
        if fn.genericParameterClause != nil { throw WinCError.noGenerics }

        let original = fn.name.text
        let symbol = original.prefix(1).uppercased() + original.dropFirst()

        // Rebuild the call to the original, preserving argument labels.
        let callArgs = fn.signature.parameterClause.parameters.map { p -> String in
            let value = (p.secondName ?? p.firstName).text     // internal name to pass
            let label = p.firstName.text                       // external label ("_" means none)
            return label == "_" ? value : "\(label): \(value)"
        }.joined(separator: ", ")

        let paramsText = fn.signature.parameterClause.trimmedDescription   // includes the parentheses
        let returnText = fn.signature.returnClause?.trimmedDescription ?? ""
        let call = "\(original)(\(callArgs))"
        let body = fn.signature.returnClause == nil ? call : "return \(call)"

        // The peer's *Swift* name is a fixed suffix of the original (so a peer macro can declare it
        // at global scope); the C symbol exposed to C# is the capitalized name in @_cdecl.
        let peerName = original + "_WinC"
        let peer: DeclSyntax = """
            #if SWIFTXWIN
            @_cdecl("\(raw: symbol)")
            public func \(raw: peerName)\(raw: paramsText) \(raw: returnText) {
                \(raw: body)
            }
            #endif
            """
        return [peer]
    }
}
