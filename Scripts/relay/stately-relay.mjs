/**
 * DEPRECATED — use `npm run relay` (stately-sky-relay.mjs) instead.
 *
 * Legacy postMessage bridge to https://stately.ai/inspect. Safari often blocks
 * this; live sessions use https://stately.ai/registry/inspect/<sessionId> via Sky.
 */
import http from 'node:http';
import { exec } from 'node:child_process';
import { platform } from 'node:os';
import { WebSocketServer } from 'ws';

const port = Number(
  process.env.PORT ??
    process.argv.find((arg, index) => process.argv[index - 1] === '--port') ??
    8080
);
const inspectorUrl = process.env.STATELY_INSPECT_URL ?? 'https://stately.ai/inspect';

function openBrowser(url) {
  const cmd =
    platform() === 'darwin' ? 'open' : platform() === 'win32' ? 'start' : 'xdg-open';
  exec(`${cmd} ${JSON.stringify(url)}`);
}

function bridgeHTML(wsPort, inspectUrl) {
  return `<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8" />
  <title>Stately Inspector Bridge</title>
  <style>
    body { font: 14px/1.4 -apple-system, BlinkMacSystemFont, sans-serif; margin: 24px; }
    .ok { color: #0a7a2f; }
    .warn { color: #9a6700; }
    .err { color: #c62828; }
    code { background: #f4f4f5; padding: 2px 6px; border-radius: 4px; }
  </style>
</head>
<body>
  <h1>Stately Inspector Bridge</h1>
  <p>WebSocket: <code>ws://127.0.0.1:${wsPort}</code></p>
  <p id="status" class="warn">Waiting for Stately Inspector window…</p>
  <p>
    If the inspector did not open,
    <a href="${inspectUrl}" target="_blank" rel="noopener">open <code>stately.ai/inspect</code></a>
    manually, then reload this page.
  </p>
  <script>
    const inspectorUrl = ${JSON.stringify(inspectUrl)};
    let inspectorWindow = window.open(inspectorUrl, 'statelyinspector');
    const buffer = [];
    let connected = false;
    const status = document.getElementById('status');

    function setStatus(text, className) {
      status.textContent = text;
      status.className = className;
    }

    window.addEventListener('message', (event) => {
      if (event.data && event.data.type === '@statelyai.connected') {
        connected = true;
        setStatus('Connected — streaming inspection events to Stately Inspector.', 'ok');
        for (const payload of buffer) {
          inspectorWindow?.postMessage(payload, '*');
        }
        buffer.length = 0;
      }
    });

    const ws = new WebSocket('ws://127.0.0.1:${wsPort}');
    ws.onopen = () => setStatus('WebSocket connected. Waiting for Stately Inspector…', 'warn');
    ws.onerror = () => setStatus('WebSocket error — is the Swift app running?', 'err');
    ws.onclose = () => setStatus('WebSocket closed.', 'err');

    ws.onmessage = (event) => {
      const data = JSON.parse(event.data);
      if (connected && inspectorWindow && !inspectorWindow.closed) {
        inspectorWindow.postMessage(data, '*');
      } else {
        buffer.push(data);
        if (buffer.length > 200) buffer.shift();
      }
    };

    if (!inspectorWindow) {
      setStatus('Popup blocked — open Stately Inspector manually using the link above.', 'err');
    }
  </script>
</body>
</html>`;
}

const httpServer = http.createServer((req, res) => {
  res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
  res.end(bridgeHTML(port, inspectorUrl));
});

const wss = new WebSocketServer({ server: httpServer });
const eventBuffer = [];
const maxBufferSize = 200;

wss.on('connection', (ws) => {
  for (const msg of eventBuffer) {
    ws.send(msg);
  }

  ws.on('message', (data) => {
    const msg = data.toString();
    eventBuffer.push(msg);
    if (eventBuffer.length > maxBufferSize) {
      eventBuffer.shift();
    }

    for (const client of wss.clients) {
      if (client !== ws && client.readyState === 1) {
        client.send(msg);
      }
    }
  });
});

httpServer.listen(port, () => {
  const bridgeUrl = `http://127.0.0.1:${port}`;
  console.log(`Stately relay WebSocket: ws://127.0.0.1:${port}`);
  console.log(`Bridge page: ${bridgeUrl}`);
  console.log(`Inspector UI: ${inspectorUrl}`);
  console.log('Opening bridge page (use HTTPS popup, not iframe)…');
  openBrowser(bridgeUrl);
});

function shutdown() {
  wss.close();
  httpServer.close();
  process.exit(0);
}

process.on('SIGINT', shutdown);
process.on('SIGTERM', shutdown);