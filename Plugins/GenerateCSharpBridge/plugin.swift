import PackagePlugin
import Foundation

/// `swift package generate-csharp-bridge` — regenerates Interop/csharp/SwiftXStateWinBridge.cs from the
/// `@WinC` functions in the SwiftXStateWinBridge target, by running the WinCBridgeGen tool.
@main
struct GenerateCSharpBridge: CommandPlugin {
    func performCommand(context: PluginContext, arguments: [String]) throws {
        let tool = try context.tool(named: "WinCBridgeGen")

        guard let target = context.package.targets.first(where: { $0.name == "SwiftXStateWinBridge" }),
              let swiftTarget = target as? SwiftSourceModuleTarget else {
            Diagnostics.error("Could not find the SwiftXStateWinBridge source target.")
            return
        }

        let sources = swiftTarget.sourceFiles
            .map { $0.path.string }
            .filter { $0.hasSuffix(".swift") }
        let output = context.package.directory
            .appending(subpath: "Interop/csharp/SwiftXStateWinBridge.cs")
            .string

        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool.path.string)
        process.arguments = [output] + sources
        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            Diagnostics.error("WinCBridgeGen exited with status \(process.terminationStatus).")
        } else {
            print("Generated \(output) from \(sources.count) source file(s).")
        }
    }
}
