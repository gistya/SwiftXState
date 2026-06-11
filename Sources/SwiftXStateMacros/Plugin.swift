import SwiftCompilerPlugin
import SwiftSyntaxMacros

@main
struct SwiftXStatePlugin: CompilerPlugin {
    let providingMacros: [Macro.Type] = [
        MachineStatesMacro.self,
        WinCMacro.self,
    ]
}
