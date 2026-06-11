// Minimal C# console app driving SwiftXState through the Windows bridge.
//
//   1. Build the bridge as a shared library with the C exports enabled:
//        SWIFTXWIN=1 swift build --product SwiftXStateWinBridge   (-c release for a real run)
//   2. Point the loader at it and run:
//        SWIFTXSTATE_BRIDGE=<path to libSwiftXStateWinBridge.dylib/.so/.dll> dotnet run
//
// On Windows the bridge name resolves to SwiftXStateWinBridge.dll directly; the resolver below also
// makes it run on macOS/Linux (dylib/so) so the round trip can be tested anywhere.

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
    {
        var path = Environment.GetEnvironmentVariable("SWIFTXSTATE_BRIDGE");
        if (string.IsNullOrEmpty(path))
            throw new InvalidOperationException(
                "Set SWIFTXSTATE_BRIDGE to the built bridge library (libSwiftXStateWinBridge.dylib/.so or SwiftXStateWinBridge.dll).");
        return NativeLibrary.Load(path);
    }
    if (name == "ucrtbase.dll")   // where free() lives
    {
        if (OperatingSystem.IsWindows()) return NativeLibrary.Load("ucrtbase.dll");
        if (OperatingSystem.IsMacOS()) return NativeLibrary.Load("/usr/lib/libSystem.B.dylib");
        return NativeLibrary.Load("libc.so.6");
    }
    return IntPtr.Zero;
}
