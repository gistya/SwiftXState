import SwiftSyntax
import SwiftSyntaxMacros
import SwiftDiagnostics

/// `@MachineStates("Name")` — a peer macro that reads the `states:` dictionary of the
/// `MachineConfig` it's attached to (recursively, through nested `StateNodeConfig`s) and generates
/// a `Name: String, StateName` enum with one case per declared state path. Because the enum is
/// generated *from* the declarations, it can never drift from them.
///
/// Each case's raw value is the dot-path from the root (`"red.wait"`), and `StateName` turns that
/// into a `#`-absolute target — which resolves regardless of where the transition is declared, so
/// it sidesteps relative-target ambiguity entirely.
public struct MachineStatesMacro: PeerMacro {
    enum MacroError: Error, CustomStringConvertible {
        case missingName
        case notAVariable
        case noMachineConfig
        var description: String {
            switch self {
            case .missingName: return "@MachineStates requires a string name, e.g. @MachineStates(\"AppState\")."
            case .notAVariable: return "@MachineStates must be attached to a let/var holding a MachineConfig (optionally wrapped in createMachine)."
            case .noMachineConfig: return "@MachineStates could not find a MachineConfig(...) initializer to read states from."
            }
        }
    }

    public static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        // 1. Enum name from the macro argument.
        guard
            let args = node.arguments?.as(LabeledExprListSyntax.self),
            let first = args.first,
            let nameLiteral = first.expression.as(StringLiteralExprSyntax.self),
            let enumName = nameLiteral.representedLiteralValue, !enumName.isEmpty
        else { throw MacroError.missingName }

        // 2. The attached declaration's initializer expression.
        guard
            let varDecl = declaration.as(VariableDeclSyntax.self),
            let initExpr = varDecl.bindings.first?.initializer?.value
        else { throw MacroError.notAVariable }

        // 3. Find the MachineConfig(...) call anywhere inside the initializer.
        guard let configCall = findCall(named: "MachineConfig", in: Syntax(initExpr)) else {
            throw MacroError.noMachineConfig
        }

        // 4. Collect state paths from its `states:` dictionary (recursively).
        var paths: [[String]] = []
        if let statesDict = dictionaryArgument(of: configCall, label: "states") {
            collect(statesDict, prefix: [], into: &paths)
        }

        // 5. Synthesize the enum, de-duplicating sanitized case names.
        var used: Set<String> = []
        var caseLines: [String] = []
        for path in paths {
            let raw = path.joined(separator: ".")
            var name = sanitize(path)
            var n = 2
            while used.contains(name) { name = "\(sanitize(path))\(n)"; n += 1 }
            used.insert(name)
            if name == raw {
                caseLines.append("    case \(escape(name))")
            } else {
                caseLines.append("    case \(escape(name)) = \"\(raw)\"")
            }
        }
        let body = caseLines.isEmpty ? "    // no states declared" : caseLines.joined(separator: "\n")

        let decl: DeclSyntax = """
        enum \(raw: enumName): String, StateName {
        \(raw: body)
        }
        """
        return [decl]
    }

    // MARK: - Syntax helpers

    /// Depth-first search for a function call whose callee is the identifier `name`.
    private static func findCall(named name: String, in syntax: Syntax) -> FunctionCallExprSyntax? {
        if let call = syntax.as(FunctionCallExprSyntax.self),
           calleeBaseName(call) == name {
            return call
        }
        for child in syntax.children(viewMode: .sourceAccurate) {
            if let found = findCall(named: name, in: child) { return found }
        }
        return nil
    }

    private static func calleeBaseName(_ call: FunctionCallExprSyntax) -> String? {
        if let ref = call.calledExpression.as(DeclReferenceExprSyntax.self) {
            return ref.baseName.text
        }
        if let member = call.calledExpression.as(MemberAccessExprSyntax.self) {
            return member.declName.baseName.text
        }
        return nil
    }

    private static func dictionaryArgument(of call: FunctionCallExprSyntax, label: String) -> DictionaryExprSyntax? {
        for arg in call.arguments where arg.label?.text == label {
            return arg.expression.as(DictionaryExprSyntax.self)
        }
        return nil
    }

    /// Recursively gather state paths: each dict key is a state; descend into its
    /// `StateNodeConfig(... states: [...] ...)` for nested states.
    private static func collect(_ dict: DictionaryExprSyntax, prefix: [String], into paths: inout [[String]]) {
        guard case let .elements(elements) = dict.content else { return }
        for element in elements {
            guard let key = stringValue(element.key) else { continue }
            let path = prefix + [key]
            paths.append(path)
            if let childCall = element.value.as(FunctionCallExprSyntax.self),
               calleeBaseName(childCall) == "StateNodeConfig",
               let childStates = dictionaryArgument(of: childCall, label: "states") {
                collect(childStates, prefix: path, into: &paths)
            }
        }
    }

    private static func stringValue(_ expr: ExprSyntax) -> String? {
        expr.as(StringLiteralExprSyntax.self)?.representedLiteralValue
    }

    // MARK: - Identifier sanitization

    /// Turn a state path into a lowerCamelCase Swift identifier (`["red","wait"] -> "redWait"`).
    private static func sanitize(_ path: [String]) -> String {
        let words = path
            .flatMap { $0.split(whereSeparator: { !$0.isLetter && !$0.isNumber }) }
            .map(String.init)
            .filter { !$0.isEmpty }
        guard let head = words.first else { return "state" }
        var result = lowerFirst(head)
        for word in words.dropFirst() { result += upperFirst(word) }
        if let f = result.first, f.isNumber { result = "_" + result }
        return result.isEmpty ? "state" : result
    }

    private static func lowerFirst(_ s: String) -> String { s.isEmpty ? s : s.prefix(1).lowercased() + s.dropFirst() }
    private static func upperFirst(_ s: String) -> String { s.isEmpty ? s : s.prefix(1).uppercased() + s.dropFirst() }

    private static let keywords: Set<String> = [
        "associatedtype","class","deinit","enum","extension","func","import","init","inout","internal",
        "let","operator","private","protocol","public","static","struct","subscript","typealias","var",
        "break","case","continue","default","defer","do","else","fallthrough","for","guard","if","in",
        "repeat","return","switch","where","while","as","catch","false","is","nil","rethrows","self",
        "super","throw","throws","true","try","Any","default",
    ]
    private static func escape(_ name: String) -> String { keywords.contains(name) ? "`\(name)`" : name }
}
