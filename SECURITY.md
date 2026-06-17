# Security

This document is a comprehensive security analysis of SwiftXState: what it does and does not do with
the network, how memory is handled across the C / C# boundary, what happens when you load an
untrusted machine definition, the supply chain, and how to harden a deployment. Claims here are
traceable to the source files named alongside them.

## Reporting a vulnerability

Please report suspected vulnerabilities privately, not in a public issue:

- Use GitHub's **"Report a vulnerability"** on the Security tab of
  <https://github.com/gistya/SwiftXState> (private security advisories).

Include a description, affected version/commit, and a reproduction if you have one. We aim to
acknowledge within a few days. Please give us a reasonable window to ship a fix before public
disclosure.

## Supported versions

Security fixes target the latest released version and `main`. Older releases are not maintained —
update to the latest version to receive fixes.

## Posture in one paragraph

The core library is a pure, in-process state-machine engine with no third-party runtime dependencies
and no networking code. Everything that can leave the process — network streaming, the C/C# bridge,
the browser build — lives in a separate, opt-in module that you have to import and wire up
deliberately. Memory safety across the one place that uses raw pointers (the Windows C ABI) rests on
ARC, opaque integer handles in lock-guarded registries, and matched allocator pairing. Machine
definitions are treated as data, not code.

## Does it touch the network?

No, not by default — and the core can't.

- **`SwiftXState` (core)** makes no network calls and contains no networking code. There is no
  `URLSession`, socket, or `Network.framework` usage anywhere under `Sources/SwiftXState/` (the only
  `http` strings in that target are in documentation prose). It cannot open a connection even if you
  ask it to; there is no API for it.
- **`SwiftXStateInspect`** is transport-agnostic plumbing. It defines the `InspectTransport` /
  `InspectSession` protocols and encodes `InspectionEvent`s to JSON, but it opens no sockets itself —
  you inject a transport. To stream anywhere you must provide a type conforming to `InspectTransport`.
- **`SwiftXStateInspectURLSession`** is the only module that actually opens a connection — an Apple
  `URLSessionWebSocketTask`. It is optional, Apple-only, and off unless you import it and start a
  session.

So network egress requires three deliberate steps: import the inspect module, supply/select a
transport, and start streaming. Nothing streams implicitly.

### The connectivity policy (loopback by default)

When you do enable streaming, where it may connect is governed by `ConnectivityPolicy`
(`Sources/SwiftXStateInspect/ConnectivityPolicy.swift`), enforced before connecting by
`EndpointValidator` (`Sources/SwiftXStateInspect/EndpointValidator.swift`):

- `.localhostOnly(ports:)` — **the default** — permits only loopback addresses (IPv4/IPv6
  `isLoopback`). A non-loopback host is rejected.
- `.privateNetwork(ports:)` — loopback plus RFC1918 / link-local (for a LAN relay). Opt-in.
- `.allowlist(hosts, ports:)` — an explicit host allowlist. Opt-in.
- `PortPolicy` (`.any` or `.only([…])`) narrows ports independently.

The default endpoint is `127.0.0.1:8080` (`URLSessionInspectTransport`). To reach anything beyond
your own machine you must consciously widen the policy. There is no "connect to the internet" default.

## What leaves your machine when you enable inspection?

The inspection stream is the serialized `InspectionEvent` feed: machine/session/actor ids, state
values, **your context serialized to JSON**, and event payloads. If your context or events carry
secrets (tokens, PII), those are in the stream. Treat inspection as a debugging facility:

- Don't enable it in production builds, or gate it behind a debug flag.
- Don't stream a context that holds secrets.
- The stream is plaintext over a local WebSocket by design (loopback). It is **not** authenticated or
  encrypted — that's acceptable for `127.0.0.1` but is why non-loopback targets are opt-in.

## The Stately relay

The live [Stately.ai](https://stately.ai) visualizer is reached through an explicit local relay you
run yourself (`Scripts/relay/`, a Node.js service). Your app streams to `ws://127.0.0.1:8080`; the
relay forwards to Stately Sky, which opens the session in your browser:

```
SwiftXState app ──ws://127.0.0.1:8080──► relay ──► Stately Sky ──► stately.ai/registry/inspect/<id>
```

This is the one path where inspection data leaves your machine, and only if you start the relay and
point it at Stately. Without the relay running, the app's localhost stream goes nowhere. See
`Scripts/relay/README.md`. Sending your inspection stream to Stately Sky shares it with a third party;
use it for debugging non-sensitive machines.

## Memory safety and the C / C# bridge

The pure-Swift library is memory-safe by construction. The one place raw pointers cross a boundary is
`SwiftXStateWinBridge` (the optional Windows C ABI consumed from C#). Its design:

- **Opaque integer handles, not pointers.** C# holds an `Int64` that indexes a lock-guarded registry
  (`BridgeRegistry` in `ActorBridge.swift`, `FlowRegistry` in `FlowMachineBridge.swift`). A forged or
  stale handle simply misses the dictionary and returns nil/`0` — there is no pointer to forge and no
  way to reach freed memory by guessing a handle.
- **ARC, no GC.** When an actor handle is released, its memory is reclaimed deterministically; there
  is no GC reachability window that re-animates a freed object. Released means gone.
- **Matched allocators.** Strings returned to C are heap-allocated with `strdup` (`dupCString`); the
  C# side frees them through `ucrtbase`'s `free`, which `NativeLoader` maps to the matching C runtime
  per OS. The DLL and the caller use the same heap, so there is no cross-allocator free corruption.
- **Lock-guarded concurrency.** C# may call from any thread. Every registry and the per-actor
  `CallbackSlot` are `NSLock`-guarded; the `@unchecked Sendable` types do their own manual locking.
  Lookups snapshot under the lock and invoke the callback *outside* it, so a callback re-entering the
  bridge can't deadlock on a non-reentrant lock.

### Residual: inspection-callback teardown

There is one documented cross-ABI contract the bridge cannot enforce for the host. The snapshot
callback is a raw `@convention(c)` pointer the host owns. `actorRelease` clears the slot before
dropping the actor (narrowing the window), but an event already mid-dispatch on the actor's thread
can still be invoking the old pointer as release returns. The host must keep the delegate alive until
after `actorRelease`, and must not swap the callback concurrently with release. See the contract on
`actorSetSnapshotCallback` / `actorRelease` in `Sources/SwiftXStateWinBridge/ActorBridge.swift`.

## Native library loading

The shipped .NET resolver (`Interop/csharp/SwiftXState/NativeLoader.cs`) loads the native bridge
**only** from `runtimes/<rid>/native` via the default search path. It honors no environment variable,
so the native load cannot be redirected by anything that can set the process environment. (A separate
dev-only harness, `Interop/csharp/Sample`, locates a freshly built library under `.build` for local
testing; that logic is not in the shipping package.)

On Windows the NuGet package bundles the official Swift runtime DLLs next to the bridge so consumers
without the Swift toolchain can load it; these come from the official swift.org toolchain at build
time (see `.github/workflows/nuget.yml`).

## Is it safe to load an untrusted machine definition?

Loading a machine **definition** (the JSON `definitionJSON()` emits, or a pasted XState config) does
not execute attacker code.

- Definitions are parsed as **data** with Foundation's `JSONDecoder`
  (`MachineDefinitionImporter`) and interpreted **structurally** by `MachineSimulator` — it walks
  states/transitions to compute initial state and available events. There is no `eval`, no
  `NSExpression`, no `dlopen`/`dlsym`, no `Process`/`system` anywhere in the core or
  `SwiftXStateInspectorCore`.
- Guards and actions are **developer-supplied Swift closures**, not data carried in the JSON. A
  definition can name a guard, but the behavior only exists if your code provides it; an unknown
  reference is inert.
- Worst case for a malicious definition is malformed JSON (rejected with an error) or a strange but
  harmless graph. Sending an unknown event is a no-op.

Caveat: this is about *definitions as data*. A machine whose guards/actions are arbitrary **Swift
code you compile and run** executes with your app's privileges — the library is not a sandbox for
untrusted Swift. Only the *data* path (pasted/loaded JSON) is hardened against code execution.

## The browser (WebAssembly) inspector

The `Examples/WasmInspector` build runs inside the browser's WebAssembly sandbox. It renders via the
DOM (JavaScriptKit) and a read-only WebGPU canvas, and the demo drives its actors in-process — it
makes no network calls of its own. It consumes an in-process `InspectionEvent` stream; if you feed it
from a networked source, that is your transport choice and the connectivity guidance above applies.

## Dependencies and supply chain

The shipped core library has **no third-party runtime dependencies**. Package-level dependencies are
build/tooling only:

- `swift-syntax` — used by the `@WinC`/macro compiler plugin at build time; nothing from it is linked
  into a consumer binary.
- `swift-docc-plugin` — documentation generation only.

`JavaScriptKit` and `swift-webgpu` appear only in the WebAssembly **example** packages
(`Examples/Wasm*`), not in any library product you'd depend on. Foundation (system) is used for JSON
coding. Pin versions via `Package.resolved`; review it as part of your own supply-chain process.

## Distribution integrity

- The NuGet package is published via **NuGet.org Trusted Publishing (OIDC)** — no long-lived API key
  is stored. Publishing is gated to version tags and routed through a `production` GitHub environment
  that can require manual approval (`.github/workflows/nuget.yml`).
- Code signing and the macOS **hardened runtime** are properties of the *app you ship*, not of a
  source library. Enable them in your application target; SwiftXState does nothing that is
  incompatible with the hardened runtime (no JIT, no disabling of library validation).

## Cryptography

The library performs no cryptography and handles no credentials or auth tokens. The inspection stream
is intentionally plaintext on loopback. If you transport it off-device, wrap it in your own
TLS/authenticated channel and widen `ConnectivityPolicy` accordingly.

## Known limitations and non-goals

- **Not a sandbox for untrusted Swift.** Guards/actions you compile run with full app privileges.
- **Inspection is unauthenticated and unencrypted** by design (loopback default). Non-loopback
  targets are opt-in and your responsibility to secure.
- **Inspection streams may contain sensitive context.** Don't enable it in production or stream
  secrets.
- **The C-callback teardown window** described above is a host-side contract, not an enforced
  guarantee.

## Hardening checklist for production

- Ship without the inspect modules, or gate inspection behind a debug-only flag.
- Keep `ConnectivityPolicy` at `.localhostOnly` unless you have a specific, secured reason to widen it.
- Never put secrets in a context you stream.
- On Windows/.NET, keep the VC++ redistributable up to date (the bridge links UCRT); deploy the
  package's bundled `runtimes/<rid>/native` contents unmodified.
- For the C/C# bridge, keep snapshot-callback delegates alive until after `actorRelease`.
- Enable code signing + hardened runtime on your app targets.
