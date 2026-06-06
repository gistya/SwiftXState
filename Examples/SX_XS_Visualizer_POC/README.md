# SX_XS_Visualizer_POC

A proof-of-concept macOS app that streams a running SwiftXState machine's **live inspection
events to the real [Stately.ai](https://stately.ai) inspector** in your browser — the same hosted
visualizer you'd use with XState on the web.

It exists to prove that SwiftXState speaks the Stately wire protocol end-to-end over a real
WebSocket. If you instead want an **in-app, native** inspector with no server and no browser, use
the `SwiftXStateInspectorUI` module (see `Examples/SwiftXChess` and `Examples/InspectorSample`) —
this POC is specifically about interop with Stately's *own* tooling.

## How it works

```
┌─────────────────────────┐   ws://127.0.0.1:8080    ┌───────────────────┐   WebSocket   ┌──────────────┐
│ SX_XS_Visualizer_POC    │ ───────────────────────► │ Node relay        │ ────────────► │ Stately Sky  │
│ (this macOS app)        │   Stately wire format     │ (Scripts/relay)   │               │              │
│  SwiftXState machine    │   URLSessionInspect       │ stately-sky-relay │               └──────┬───────┘
└─────────────────────────┘                           └───────────────────┘                      │
                                                                                                  ▼
                                                              browser: https://stately.ai/registry/inspect/<sessionId>
```

1. The app runs a SwiftXState machine and emits inspection events through
   `SwiftXStateInspectURLSession` to a **localhost WebSocket** (default `ws://127.0.0.1:8080`),
   using the **Stately wire format** and a `.localhostOnly(ports: .only([8080]))` transport policy.
2. A small **Node relay** (in `Scripts/relay`) listens on that port, forwards the events
   to **Stately Sky**, and opens a live session URL in your browser.
3. Stately renders the machine graph and live state/events — exactly as it would for a JS XState app.

> The app target ships with the App Sandbox **outgoing-network (`network.client`)** entitlement,
> which is why this POC — rather than a plain SPM example — is used to open the localhost socket.

## Setup

You need **Node.js** (for the relay) and **Xcode** (for the app).

### 1. Start the relay

```bash
cd Scripts/relay
npm install
npm run relay          # starts the relay on :8080 and opens a Stately session in your browser
```

`npm run relay` runs `stately-sky-relay.mjs`. It prints (and opens) a URL like
`https://stately.ai/registry/inspect/<sessionId>`.

> **Open that printed URL** — not the generic `https://stately.ai/inspect` landing page (it won't
> show a session). Works in Safari and Firefox. Use `npm run relay:debug` for verbose logging.

### 2. Run the app

Open `SX_XS_Visualizer_POC.xcodeproj` in Xcode and run the **SX_XS_Visualizer_POC** scheme (macOS).

The app connects to `ws://127.0.0.1:8080` on launch. Pick a sample machine, tap the event buttons,
and watch the state transitions appear live in the Stately tab in your browser. The app's
**Stately Inspector** card shows the current connection status and endpoint.

## Sample machines

Toggle · Counter · Feedback · Traffic Light · Checkout Pipeline — small machines ported from XState
examples/templates, exercising guards, context, parallel regions, and invoked actors.

## Configuration

Defaults live in `InspectSampleSession.swift`:

| Setting | Default | Notes |
|---------|---------|-------|
| Host    | `127.0.0.1` | localhost only |
| Port    | `8080` | must match the relay's `PORT` (override with `PORT=9000 npm run relay`) |
| Wire format | `.stately` | what Stately expects |
| Transport policy | `.localhostOnly(ports: .only([8080]))` | refuses non-localhost endpoints |

## Troubleshooting

- **Nothing appears in the browser** — start the relay *before* the app, and make sure you opened
  the `…/registry/inspect/<sessionId>` URL the relay printed (not `stately.ai/inspect`).
- **Connection refused / status stuck on "Idle"** — the relay isn't running, or the app's port
  doesn't match the relay's. Both default to `8080`.
- **Sandbox blocks the socket** — make sure you're running the **SX_XS_Visualizer_POC** target
  (it carries the `network.client` entitlement), not another example.
- **Safari blocks the legacy bridge** — use `npm run relay` (Sky); `npm run relay:legacy` is the
  older `postMessage` bridge and is deprecated.

## Related

- **`Scripts/relay`** — the Node relay (shared tooling): `npm run relay` bridges any SwiftXState app to Stately.
- **`Examples/InspectorSample`** — another example app that connects through the same relay.
- **`SwiftXStateInspectorUI`** — the **native** in-app inspector (no relay, no browser). Preferred for
  shipping apps; this POC is for verifying Stately interop.
