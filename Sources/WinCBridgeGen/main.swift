import Foundation
import SwiftSyntax
import SwiftParser

// WinCBridgeGen <output.cs> <source.swift> [<source.swift> ...]
//
// Scans the given Swift sources for `@WinC` functions and writes the matching C# P/Invoke wrappers.
// This is the honest version of "the macro adds a .cs entry": a macro can't write files, so a codegen
// step reads the same annotations and keeps Interop/csharp/SwiftXStateWinBridge.cs in sync.

let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count >= 2 else {
    FileHandle.standardError.write(Data("usage: WinCBridgeGen <out.cs> <src.swift> [...]\n".utf8))
    exit(2)
}
let outputPath = arguments[0]
let sourcePaths = Array(arguments.dropFirst())

struct Param { let name: String; let type: String }
struct Export { let symbol: String; let params: [Param]; let returnType: String }

func capitalizeFirst(_ s: String) -> String { s.prefix(1).uppercased() + s.dropFirst() }

/// C# reserved words that would be illegal as identifiers; escape with a leading `@`.
let csharpKeywords: Set<String> = [
    "abstract", "as", "base", "bool", "break", "byte", "case", "catch", "char", "checked", "class",
    "const", "continue", "decimal", "default", "delegate", "do", "double", "else", "enum", "event",
    "explicit", "extern", "false", "finally", "fixed", "float", "for", "foreach", "goto", "if",
    "implicit", "in", "int", "interface", "internal", "is", "lock", "long", "namespace", "new",
    "null", "object", "operator", "out", "override", "params", "private", "protected", "public",
    "readonly", "ref", "return", "sbyte", "sealed", "short", "sizeof", "stackalloc", "static",
    "string", "struct", "switch", "this", "throw", "true", "try", "typeof", "uint", "ulong",
    "unchecked", "unsafe", "ushort", "using", "virtual", "void", "volatile", "while",
]
func csIdentifier(_ name: String) -> String { csharpKeywords.contains(name) ? "@\(name)" : name }

/// Collects every top-level `@WinC func`.
final class WinCCollector: SyntaxVisitor {
    var exports: [Export] = []
    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        let isWinC = node.attributes.contains { element in
            element.as(AttributeSyntax.self)?.attributeName.trimmedDescription == "WinC"
        }
        guard isWinC else { return .visitChildren }
        let params = node.signature.parameterClause.parameters.enumerated().map { index, p -> Param in
            var name = (p.secondName ?? p.firstName).text
            if name == "_" { name = "arg\(index)" }
            return Param(name: name, type: p.type.trimmedDescription.replacingOccurrences(of: " ", with: ""))
        }
        let ret = node.signature.returnClause?.type.trimmedDescription.replacingOccurrences(of: " ", with: "") ?? "Void"
        exports.append(Export(symbol: capitalizeFirst(node.name.text), params: params, returnType: ret))
        return .visitChildren
    }
}

let collector = WinCCollector(viewMode: .sourceAccurate)
for path in sourcePaths {
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
    collector.walk(Parser.parse(source: text))
}
let exports = collector.exports.sorted { $0.symbol < $1.symbol }

// MARK: - Swift C-type → C# mapping

func isCString(_ t: String) -> Bool { t.contains("Pointer<CChar>") }

/// (nativeParam, publicParam, callArg) for a parameter in C#.
func mapParam(_ p: Param) -> (native: String, publicParam: String, call: String) {
    let name = csIdentifier(p.name)
    switch p.type {
    case "Int32": return ("int \(name)", "int \(name)", name)
    case "Int64": return ("long \(name)", "long \(name)", name)
    case "Float": return ("float \(name)", "float \(name)", name)
    case "Double": return ("double \(name)", "double \(name)", name)
    default:
        if p.type.contains("CCallback") {  // @convention(c) callback → a C# cdecl delegate
            return ("SnapshotCallback \(name)", "SnapshotCallback \(name)", name)
        }
        if isCString(p.type) {  // UnsafePointer<CChar>(?) — a C string in
            return ("[MarshalAs(UnmanagedType.LPUTF8Str)] string \(name)", "string \(name)", name)
        }
        return ("IntPtr \(name) /* unmapped: \(p.type) */", "IntPtr \(name)", name)
    }
}

enum ReturnKind { case void, int, long, float, double, str, raw(String) }
func mapReturn(_ t: String) -> ReturnKind {
    if t == "Void" { return .void }
    if isCString(t) { return .str }
    switch t {
    case "Int32": return .int
    case "Int64": return .long
    case "Float": return .float
    case "Double": return .double
    default: return .raw(t)
    }
}

func nativeReturnType(_ k: ReturnKind) -> String {
    switch k {
    case .void: return "void"; case .int: return "int"; case .long: return "long"
    case .float: return "float"; case .double: return "double"; case .str: return "IntPtr"; case .raw: return "IntPtr"
    }
}
func publicReturnType(_ k: ReturnKind) -> String {
    switch k {
    case .void: return "void"; case .int: return "int"; case .long: return "long"
    case .float: return "float"; case .double: return "double"; case .str: return "string"; case .raw: return "IntPtr"
    }
}

// MARK: - Emit

var out = """
// <auto-generated> by WinCBridgeGen — do not edit by hand.
// Regenerate with:  swift package generate-csharp-bridge
// Source of truth: the @WinC functions in Sources/SwiftXStateWinBridge.
using System;
using System.Runtime.InteropServices;

namespace SwiftXStateWinBridgeInterop
{
    public static class SwiftXStateWinBridge
    {
        private const string DllName = "SwiftXStateWinBridge.dll";

        // Free a C string that Swift allocated (Universal C Runtime `free`).
        [DllImport("ucrtbase.dll", EntryPoint = "free", CallingConvention = CallingConvention.Cdecl)]
        private static extern void FreeCString(IntPtr ptr);

        // Read a UTF-8 C string from Swift and free it. Swift strings are UTF-8.
        private static string ConsumeCString(IntPtr ptr)
        {
            if (ptr == IntPtr.Zero) return string.Empty;
            try { return Marshal.PtrToStringUTF8(ptr) ?? string.Empty; }
            finally { FreeCString(ptr); }
        }

        // Live inspection callback: one JSON document per event. Keep your delegate instance alive for
        // as long as it's registered, or the GC may collect it. The json string is a copy you own.
        [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
        public delegate void SnapshotCallback([MarshalAs(UnmanagedType.LPUTF8Str)] string json);

"""

for e in exports {
    let kind = mapReturn(e.returnType)
    let mapped = e.params.map(mapParam)
    let nativeParams = mapped.map(\.native).joined(separator: ", ")
    let publicParams = mapped.map(\.publicParam).joined(separator: ", ")
    let callArgs = mapped.map(\.call).joined(separator: ", ")

    out += "\n        // --- \(e.symbol) ---\n"
    out += "        [DllImport(DllName, EntryPoint = \"\(e.symbol)\", CallingConvention = CallingConvention.Cdecl)]\n"
    out += "        private static extern \(nativeReturnType(kind)) Native\(e.symbol)(\(nativeParams));\n\n"

    switch kind {
    case .void:
        out += "        public static void \(e.symbol)(\(publicParams)) => Native\(e.symbol)(\(callArgs));\n"
    case .str:
        out += "        public static string \(e.symbol)(\(publicParams)) => ConsumeCString(Native\(e.symbol)(\(callArgs)));\n"
    default:
        out += "        public static \(publicReturnType(kind)) \(e.symbol)(\(publicParams)) => Native\(e.symbol)(\(callArgs));\n"
    }
}

out += "    }\n}\n"

do {
    try out.write(toFile: outputPath, atomically: true, encoding: .utf8)
    FileHandle.standardError.write(Data("WinCBridgeGen: wrote \(exports.count) exports to \(outputPath)\n".utf8))
} catch {
    FileHandle.standardError.write(Data("WinCBridgeGen: failed to write \(outputPath): \(error)\n".utf8))
    exit(1)
}
