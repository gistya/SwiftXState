/**
 * Relays SwiftXState inspection events to Stately Sky, then opens a live
 * session URL: https://stately.ai/registry/inspect/<sessionId>
 *
 * Do NOT open https://stately.ai/inspect — that page is only a landing screen.
 *
 * Debug mode: `npm run relay:debug` or `node stately-sky-relay.mjs --debug`
 */
import { createInspector } from '@statelyai/inspect';
import { exec } from 'node:child_process';
import http from 'node:http';
import { platform } from 'node:os';
import PartySocket from 'partysocket';
import { stringify } from 'superjson';
import { v4 as uuidv4 } from 'uuid';
import WebSocket, { WebSocketServer } from 'ws';
import { createRelayDebugLogger } from './relay-debug.mjs';

const debug = createRelayDebugLogger();

const SKY_HOST = 'stately-sky-beta.mellson.partykit.dev';
const SKY_API_BASE = 'https://stately.ai/registry/api/sky';
const SKY_INSPECT_BASE = SKY_API_BASE.replace('/api/sky', '/inspect');

const port = Number(
  process.env.PORT ??
    process.argv.find((arg, index) => process.argv[index - 1] === '--port') ??
    8080
);

const sessionId = uuidv4();
const room = `inspect-${sessionId}`;
const liveUrl = `${SKY_INSPECT_BASE}/${sessionId}`;

function openBrowser(url) {
  const cmd =
    platform() === 'darwin' ? 'open' : platform() === 'win32' ? 'start' : 'xdg-open';
  exec(`${cmd} ${JSON.stringify(url)}`);
}

const skySocket = new PartySocket({
  host: SKY_HOST,
  room,
  WebSocket,
});

const skyQueue = [];
let skyReady = false;

const skyInspector = createInspector({
  send(event) {
    const payload = stringify(event);
    if (skyReady) {
      skySocket.send(payload);
    } else {
      skyQueue.push(payload);
      if (skyQueue.length > 200) {
        skyQueue.shift();
      }
    }
  },
});

skySocket.onopen = () => {
  skyReady = true;
  if (debug.flags.debug) {
    debug.noteSkyOpen(liveUrl);
  } else {
    console.log('');
    console.log('=== Stately Inspector session ===');
    console.log(liveUrl);
    console.log('=================================');
    console.log('Open that URL if your browser did not open it automatically.');
    console.log('');
  }
  openBrowser(liveUrl);
  const queued = skyQueue.length;
  for (const payload of skyQueue) {
    skySocket.send(payload);
  }
  skyQueue.length = 0;
  debug.noteSkyFlush(queued);
};

skySocket.onerror = (error) => {
  if (debug.flags.debug) {
    debug.noteSkyError(error);
  } else {
    console.error('Sky connection error:', error);
  }
};

function forwardToSky(rawMessage) {
  const event = JSON.parse(rawMessage);
  skyInspector.adapter.send(event);
}

function statusHTML() {
  return `<!DOCTYPE html>
<html><head><meta charset="utf-8"><title>SwiftXState Inspect Relay</title>
<style>
body{font:14px/1.5 -apple-system,sans-serif;margin:24px;max-width:720px}
code{background:#f4f4f5;padding:2px 6px;border-radius:4px}
a{color:#0b57d0}
.warn{color:#9a6700}
</style></head>
<body>
<h1>SwiftXState → Stately Sky Relay</h1>
<p>Session: <code>${sessionId}</code></p>
<p>WebSocket: <code>ws://127.0.0.1:${port}</code></p>
<p>Inspector: <a href="${liveUrl}">${liveUrl}</a></p>
<p>Sky status: <strong>${skyReady ? 'connected' : 'connecting…'}</strong></p>
<p class="warn">Use the <strong>registry</strong> link above — <code>stately.ai/inspect</code> without a session id is only a landing page.</p>
<p>Run the Xcode sample app, then send events. The inspector tab should update live.</p>
</body></html>`;
}

const httpServer = http.createServer((req, res) => {
  res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
  res.end(statusHTML());
});

const wss = new WebSocketServer({ server: httpServer });
const eventBuffer = [];

wss.on('connection', (ws) => {
  if (debug.flags.debug) {
    debug.noteClientConnected();
  } else {
    console.log('Client connected (SwiftXState)');
  }
  for (const msg of eventBuffer) {
    ws.send(msg);
  }

  ws.on('close', () => {
    debug.noteClientDisconnected();
  });

  ws.on('message', (data) => {
    const msg = data.toString();
    debug.inspectMessage(msg);
    try {
      forwardToSky(msg);
    } catch (error) {
      if (debug.flags.debug) {
        debug.noteInvalidJSON(error);
      } else {
        console.error('Invalid inspection JSON:', error);
      }
      return;
    }

    if (!skyReady) {
      debug.noteSkyQueued(skyQueue.length);
    }

    eventBuffer.push(msg);
    if (eventBuffer.length > 200) {
      eventBuffer.shift();
    }

    for (const client of wss.clients) {
      if (client !== ws && client.readyState === WebSocket.OPEN) {
        client.send(msg);
      }
    }
  });
});

httpServer.listen(port, () => {
  if (debug.flags.debug) {
    debug.noteStartup({ port, liveUrl, sessionId });
  } else {
    console.log(`Relay WebSocket: ws://127.0.0.1:${port}`);
    console.log(`Status page: http://127.0.0.1:${port}`);
    console.log(`Inspector (opens when Sky connects): ${liveUrl}`);
  }
  openBrowser(`http://127.0.0.1:${port}`);
});

function shutdown() {
  skySocket.close();
  wss.close();
  httpServer.close();
  process.exit(0);
}

process.on('SIGINT', shutdown);
process.on('SIGTERM', shutdown);