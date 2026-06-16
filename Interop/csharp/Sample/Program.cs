// Minimal C# console app driving SwiftXState through the Windows bridge.
//
//   1. Build the bridge as a shared library with the C exports enabled:
//        SWIFTXWIN=1 swift build --product SwiftXStateWinBridge   (-c release for a real run)
//   2. Run it:
//        dotnet run --project Interop/csharp/Sample
//
// The resolver below finds the just-built library in the package's `.build` output (and maps the
// name onto the right native file for the current OS), so the round trip runs on macOS/Linux/Windows
// with no environment variables. This is a test harness; the shipping package resolves the native
// library only from runtimes/<rid>/native (see SwiftXState/NativeLoader.cs).

using System.Reflection;
using System.Runtime.InteropServices;
using SwiftXStateWinBridgeInterop;

NativeLibrary.SetDllImportResolver(typeof(SwiftXStateWinBridge).Assembly, Resolve);

// Live inspection: SwiftXState pushes one JSON document per event. Keep the delegate alive.
var onEvent = new SwiftXStateWinBridge.SnapshotCallback(json =>
    Console.WriteLine("  [inspect] " + Truncate(json)));

Console.WriteLine("SwiftXState from C#");
Console.WriteLine("-------------------");
Console.WriteLine("version : " + SwiftXStateWinBridge.SwiftXStateVersion());
Console.WriteLine("machines: " + SwiftXStateWinBridge.MachineList());

// --- counter: send events, watch context + the live inspection stream ---
long counter = SwiftXStateWinBridge.ActorCreate("counter");
Console.WriteLine($"\ncounter (handle {counter}) — subscribing to live events");
SwiftXStateWinBridge.ActorSetSnapshotCallback(counter, onEvent);
Console.WriteLine("state: " + SwiftXStateWinBridge.ActorState(counter));
foreach (var ev in new[] { "INC", "INC", "DEC", "NOPE" })
{
    int moved = SwiftXStateWinBridge.ActorSend(counter, ev);
    Console.WriteLine($"send {ev,-5} moved={moved}  context={SwiftXStateWinBridge.ActorContextJSON(counter)}");
}
SwiftXStateWinBridge.ActorRelease(counter);

// --- vending: a guard that needs 3 credits before DISPENSE transitions ---
long vending = SwiftXStateWinBridge.ActorCreate("vending");
Console.WriteLine($"\nvending (handle {vending}) events: {SwiftXStateWinBridge.ActorEvents(vending)}");
Console.WriteLine("DISPENSE @ 0 credits moved=" + SwiftXStateWinBridge.ActorSend(vending, "DISPENSE"));
for (int i = 0; i < 3; i++) SwiftXStateWinBridge.ActorSend(vending, "COIN");
Console.WriteLine("after 3x COIN context=" + SwiftXStateWinBridge.ActorContextJSON(vending));
Console.WriteLine("DISPENSE @ 3 credits moved=" + SwiftXStateWinBridge.ActorSend(vending, "DISPENSE")
                  + " state=" + SwiftXStateWinBridge.ActorState(vending));
SwiftXStateWinBridge.ActorRelease(vending);

GC.KeepAlive(onEvent);
return;

static string Truncate(string s, int max = 160) => s.Length <= max ? s : s[..max] + "…";

// Map the DLL names the bridge references onto the right native library for the current OS.
static IntPtr Resolve(string name, Assembly assembly, DllImportSearchPath? searchPath)
{
    if (name == "SwiftXStateWinBridge.dll")
        return LoadBridge(assembly, searchPath);
    if (name == "ucrtbase.dll")   // where free() lives
    {
        if (OperatingSystem.IsWindows()) return NativeLibrary.Load("ucrtbase.dll");
        if (OperatingSystem.IsMacOS()) return NativeLibrary.Load("/usr/lib/libSystem.B.dylib");
        return NativeLibrary.Load("libc.so.6");
    }
    return IntPtr.Zero;
}

// Locate the bridge built by `swift build`. No environment variable: try the test binary's own
// directory (in case it was copied there), then walk up to the package's `.build/{debug,release}`.
static IntPtr LoadBridge(Assembly assembly, DllImportSearchPath? searchPath)
{
    var file = OperatingSystem.IsWindows() ? "SwiftXStateWinBridge.dll"
             : OperatingSystem.IsMacOS()   ? "libSwiftXStateWinBridge.dylib"
             :                               "libSwiftXStateWinBridge.so";

    // 1) Next to the running binary (default search), e.g. if copied into the output directory.
    if (NativeLibrary.TryLoad(file, assembly, searchPath, out var handle))
        return handle;

    // 2) The local `swift build` output: walk up to the repo's `.build` and check both configs.
    for (var dir = new DirectoryInfo(AppContext.BaseDirectory); dir is not null; dir = dir.Parent)
    {
        var build = Path.Combine(dir.FullName, ".build");
        if (!Directory.Exists(build))
            continue;
        foreach (var config in new[] { "debug", "release" })
        {
            var candidate = Path.Combine(build, config, file);
            if (File.Exists(candidate) && NativeLibrary.TryLoad(candidate, out var lib))
                return lib;
        }
        break; // found the package's .build; stop climbing
    }

    throw new InvalidOperationException(
        $"Could not find {file}. Build it first:  SWIFTXWIN=1 swift build --product SwiftXStateWinBridge");
}
