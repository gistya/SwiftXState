# SwiftXState · WebAssembly demo

A proof of concept: the **SwiftXState core engine compiled to WebAssembly**, running live in the
browser, driving the DOM through [JavaScriptKit](https://github.com/swiftwasm/JavaScriptKit). No
server-side logic — the machines are pure SwiftXState executing client-side.

It's a small **gallery**: pick a machine from the sidebar and send it events. The detail pane
shows the live state, a generic `context` summary (rendered via `Mirror`), and one button per
event the machine declares — each automatically **disabled when `snapshot.can(event)` is false**,
so guards visibly gate the UI.

It depends only on the **core `SwiftXState`** product (no AppKit/SwiftUI/SceneKit), which is what
makes it Wasm-clean.

## Sample machines

| Machine | Shows off |
|---|---|
| **Toggle** | The simplest machine — two states, one event |
| **Traffic light** | States + an `assign` action counting completed cycles |
| **Vending machine** | A **guard** + context: `DISPENSE` only fires at ≥ 3 credits |
| **Checkout flow** | A linear multi-step flow with forward/back transitions |
| **Fetch (manual)** | load / success / failure with a retry guard |

The machines are deliberately **event-driven** (no `after:`/async), because timers and Swift
concurrency behave differently under WebAssembly — see the Clock note in the main repo.

## What it demonstrates (verified in-browser)

- `createMachine` / `createActor` / `send` / `snapshot` running in the browser
- State transitions reflected live in the UI
- `assign` actions mutating `context` (e.g. vending credits, traffic-light cycles)
- **Guard evaluation** driving button enable/disable via `snapshot.can(_:)`
- Generic context display through Swift `Mirror` reflection

Confirmed end-to-end with a headless browser: e.g. selecting *Vending machine*, sending three
`COIN` events takes `credits` to 3, at which point the `DISPENSE` button (guarded on
`credits >= 3`) becomes enabled.

## Prerequisites

- A swift.org **WebAssembly SDK** — check with `swift sdk list`. The build script defaults to
  `swift-6.3.2-RELEASE_wasm`; override with `WASM_SDK=…`. Install SDKs from
  [swift.org/install](https://www.swift.org/install).
- **Node.js + npm** (for esbuild and the browser WASI shim).
- *Optional but recommended:* **binaryen** (`brew install binaryen`) for `wasm-opt`, which the
  PackageToJS plugin uses to shrink the binary (see size note below).

## Build & run locally

```sh
./build.sh                 # → produces a self-contained ./site directory
npx --yes serve site       # serve it (any static server works)
# open the printed http://localhost:… URL
```

`build.sh` compiles to wasm via the PackageToJS plugin, installs the WASI shim, bundles the JS
loader with esbuild, and copies `WasmDemo.wasm` + `index.html` into `site/`.

## ⚠️ Binary size

The generated `WasmDemo.wasm` is **large — ~60 MB unoptimized.** This is the cost of full Swift
**stdlib + Foundation** on Wasm (the same reason Embedded-Swift UI frameworks like ElementaryUI
advertise kB-sized bundles — they drop Foundation and most of the stdlib). To bring it down:

- Install **binaryen** so PackageToJS runs `wasm-opt` (significant shrink).
- Serve with **gzip/brotli** — GitHub Pages does this automatically, cutting the over-the-wire
  size several-fold.

Even so, expect a multi-MB download. For a POC that's fine; for a production web target you'd want
to investigate an Embedded-Swift core (a much larger undertaking — SwiftXState's core currently
relies on Foundation, existentials, and reflection that Embedded Swift doesn't support).

## Hosting on GitHub Pages

The output is plain static files (`.wasm` + `.js` + `.html`), so any static host works. A
single-threaded Wasm app needs **no** COOP/COEP headers, so GitHub Pages serves it fine.

**Note:** this monorepo's Pages environment is already used by the DocC docs workflow
(`.github/workflows/static.yml`), and a repo can only have **one** Pages site. So pick one:

1. **Dedicated repo (simplest):** copy this `Examples/WasmDemo` folder into its own repository and
   add the template workflow [`pages-deploy.yml.template`](pages-deploy.yml.template) as
   `.github/workflows/deploy.yml`. It builds and publishes to that repo's Pages.
2. **Fold into the docs site:** extend `static.yml` to also run `build.sh` and copy `site/` into
   `docs/demo/`, so the demo lands at `…/SwiftXState/demo/` alongside the documentation. (Couples
   the docs deploy with a Wasm build — heavier, but one site.)

## Files

| File | Purpose |
|---|---|
| `Package.swift` | Executable target depending on core `SwiftXState` + JavaScriptKit |
| `Sources/WasmDemo/Machines.swift` | The sample machines + a type-erased `DemoSession` |
| `Sources/WasmDemo/main.swift` | The JavaScriptKit gallery UI |
| `index.html` | Loads the bundled module and calls `init()` |
| `build.sh` | Wasm build → JS bundle → static `site/` |
| `pages-deploy.yml.template` | GitHub Actions workflow for a dedicated-repo deploy |

> **Build via `build.sh` / the PackageToJS plugin**, not a bare `swift build --swift-sdk …wasm`.
> The latter tries to compile JavaScriptKit's BridgeJS *build-tool* for the wasm triple (it needs
> Dispatch and fails); the `swift package … js` command plugin builds host tools correctly.
