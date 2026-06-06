# Stately relay

Shared Node tooling that bridges **any** SwiftXState app's inspection stream to the live
[Stately.ai](https://stately.ai) inspector. A SwiftXState app (via `SwiftXStateInspectURLSession`)
streams events to a localhost WebSocket; this relay forwards them to Stately Sky and opens the
live session in your browser.

```
SwiftXState app  ──ws://127.0.0.1:8080──►  this relay  ──►  Stately Sky  ──►  stately.ai/registry/inspect/<id>
```

## Usage

```bash
cd Scripts/relay
npm install
npm run relay          # starts on :8080, opens the session URL in your browser
```

Open the printed `https://stately.ai/registry/inspect/<sessionId>` URL — **not** the generic
`stately.ai/inspect` landing page. Works in Safari and Firefox.

| Script | What it does |
|--------|--------------|
| `npm run relay` | `stately-sky-relay.mjs` — the current Sky relay (recommended) |
| `npm run relay:debug` | same, with verbose logging |
| `npm run relay:legacy` | `stately-relay.mjs` — deprecated `postMessage` bridge to `stately.ai/inspect` |

Override the port with `PORT=9000 npm run relay` (the app's transport must point at the same port).

## Who uses it

- **`Examples/SX_XS_Visualizer_POC`** — a macOS app with the network-client entitlement; the primary
  demo of live Stately interop.
- **`Examples/InspectorSample`** — sample machines wired to the relay.

The app side connects with `URLSessionInspect.transport(policy: .localhostOnly(ports: .only([8080])))`
and `wireFormat: .stately`. For an **in-app** inspector that needs no relay and no browser, use the
`SwiftXStateInspectorUI` module instead.
