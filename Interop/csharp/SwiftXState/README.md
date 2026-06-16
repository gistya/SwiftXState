# SwiftXState for .NET

C# bindings for [SwiftXState](https://github.com/gistya/SwiftXState) — drive native Swift statecharts
from .NET: create actors, send events, read state and context, and subscribe to the live inspection
stream.

```csharp
using SwiftXStateWinBridgeInterop;

long actor = SwiftXStateWinBridge.ActorCreate("counter");

SwiftXStateWinBridge.ActorSetSnapshotCallback(actor, json =>
    Console.WriteLine(json));            // live @xstate.* events as JSON

SwiftXStateWinBridge.ActorSend(actor, "INC");
Console.WriteLine(SwiftXStateWinBridge.ActorState(actor));        // "running"
Console.WriteLine(SwiftXStateWinBridge.ActorContextJSON(actor));  // {"count":"1"}

SwiftXStateWinBridge.ActorRelease(actor);
```

The native bridge is bundled per platform under `runtimes/<rid>/native`; the right one is loaded
automatically from there and nowhere else — the resolver has no environment-variable override, so the
native load can't be redirected by the process environment. (For local development against a fresh
`swift build`, the `Interop/csharp/Sample` harness locates the library in `.build` itself.)
