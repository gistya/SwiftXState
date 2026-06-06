/**
 * Console logging helpers for the Stately Sky relay.
 */

function parseArgs(argv) {
  const flags = {
    debug: false,
    verbose: false,
    filter: null,
  };

  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === '--debug' || arg === '-d') {
      flags.debug = true;
    } else if (arg === '--verbose' || arg === '-v') {
      flags.verbose = true;
      flags.debug = true;
    } else if (arg === '--filter' || arg === '-f') {
      flags.filter = argv[index + 1] ?? null;
      index += 1;
    } else if (arg.startsWith('--filter=')) {
      flags.filter = arg.slice('--filter='.length) || null;
    }
  }

  if (process.env.RELAY_DEBUG === '1' || process.env.RELAY_DEBUG === 'true') {
    flags.debug = true;
  }
  if (process.env.RELAY_VERBOSE === '1' || process.env.RELAY_VERBOSE === 'true') {
    flags.verbose = true;
    flags.debug = true;
  }
  if (process.env.RELAY_FILTER) {
    flags.filter = process.env.RELAY_FILTER;
  }

  return flags;
}

function timestamp() {
  return new Date().toISOString().slice(11, 23);
}

function shortId(id) {
  if (!id) return '-';
  return id.length > 12 ? `${id.slice(0, 8)}…` : id;
}

function formatStateValue(value) {
  if (value == null) return '-';
  if (typeof value === 'string') return value;
  try {
    return JSON.stringify(value);
  } catch {
    return String(value);
  }
}

function eventLabel(event) {
  return event.name ?? shortId(event.sessionId);
}

function matchesFilter(event, filter) {
  if (!filter) return true;
  const needle = filter.toLowerCase();
  const haystack = [
    event.type,
    event.name,
    event.sessionId,
    event.rootId,
    event.parentId,
    event.sourceId,
    event.event?.type,
    event.action?.type,
  ]
    .filter(Boolean)
    .join(' ')
    .toLowerCase();
  return haystack.includes(needle);
}

function summarizeInspectEvent(event) {
  const label = eventLabel(event);

  switch (event.type) {
    case '@xstate.actor':
      return `actor register name=${label} parent=${shortId(event.parentId)} status=${event.snapshot?.status ?? 'active'}`;
    case '@xstate.event':
      return `event ${label} type=${event.event?.type ?? '?'} source=${shortId(event.sourceId)}`;
    case '@xstate.snapshot':
      return `snapshot ${label} state=${formatStateValue(event.snapshot?.value)} trigger=${event.event?.type ?? '-'}`;
    case '@xstate.transition':
      return `transition ${label} state=${formatStateValue(event.snapshot?.value)} via=${event.event?.type ?? '?'}`;
    case '@xstate.microstep':
      return `microstep ${label} state=${formatStateValue(event.snapshot?.value)} via=${event.event?.type ?? '?'}`;
    case '@xstate.action':
      return `action ${label} type=${event.action?.type ?? '?'}`;
    default:
      return `${event.type ?? 'unknown'} ${label}`;
  }
}

export function createRelayDebugLogger(argv = process.argv.slice(2)) {
  const flags = parseArgs(argv);
  let eventCount = 0;
  let skippedCount = 0;
  const registeredSessions = new Set();

  function log(level, message) {
    if (!flags.debug) return;
    const prefix = `[relay ${timestamp()}]`;
    if (level === 'error') {
      console.error(prefix, message);
    } else {
      console.log(prefix, message);
    }
  }

  return {
    flags,
    log,
    noteClientConnected() {
      log('info', 'SwiftXState client connected');
    },
    noteClientDisconnected() {
      log('info', 'SwiftXState client disconnected');
    },
    noteSkyOpen(liveUrl) {
      log('info', `Sky connected — inspector ${liveUrl}`);
    },
    noteSkyError(error) {
      log('error', `Sky error: ${error?.message ?? error}`);
    },
    noteSkyQueued(count) {
      log('info', `Sky not ready — queued ${count} event(s)`);
    },
    noteSkyFlush(count) {
      if (count > 0) {
        log('info', `Flushed ${count} queued event(s) to Sky`);
      }
    },
    noteInvalidJSON(error) {
      log('error', `Invalid inspection JSON: ${error?.message ?? error}`);
    },
    noteStartup({ port, liveUrl, sessionId }) {
      if (!flags.debug) return;
      console.log('');
      console.log('=== Stately Inspector relay (debug) ===');
      console.log(`Session: ${sessionId}`);
      console.log(`WebSocket: ws://127.0.0.1:${port}`);
      console.log(`Inspector: ${liveUrl}`);
      if (flags.filter) {
        console.log(`Filter: ${flags.filter}`);
      }
      console.log('Debug logs: on (use --verbose for full JSON)');
      console.log('=======================================');
      console.log('');
    },
    inspectMessage(rawMessage) {
      if (!flags.debug) return;

      let event;
      try {
        event = JSON.parse(rawMessage);
      } catch (error) {
        log('error', `Invalid inspection JSON: ${error?.message ?? error}`);
        return;
      }

      if (!matchesFilter(event, flags.filter)) {
        skippedCount += 1;
        return;
      }

      if (event.type === '@xstate.actor' && event.sessionId) {
        registeredSessions.add(event.sessionId);
      }

      if (
        event.sessionId &&
        (event.type === '@xstate.event' ||
          event.type === '@xstate.snapshot' ||
          event.type === '@xstate.transition' ||
          event.type === '@xstate.microstep' ||
          event.type === '@xstate.action') &&
        !registeredSessions.has(event.sessionId)
      ) {
        log(
          'error',
          `Event for unregistered session ${event.name ?? shortId(event.sessionId)} (${event.type}) — Stately will likely crash (missing @xstate.actor)`
        );
      }

      if (event.type === '@xstate.actor' && event.definition) {
        try {
          const definition = JSON.parse(event.definition);
          // Lazy-load xstate only when node is available (relay runs under node).
          import('xstate')
            .then(({ createMachine }) => {
              createMachine(definition);
            })
            .catch((error) => {
              log(
                'error',
                `Definition rejected for ${event.name ?? event.sessionId}: ${error?.message ?? error}`
              );
            });
        } catch (error) {
          log('error', `Definition JSON parse failed for ${event.name ?? event.sessionId}: ${error?.message ?? error}`);
        }
      }

      eventCount += 1;
      const summary = summarizeInspectEvent(event);
      if (flags.verbose) {
        log('info', `#${eventCount} ${summary}`);
        console.log(JSON.stringify(event, null, 2));
      } else {
        log('info', `#${eventCount} ${summary}`);
      }
    },
    stats() {
      return { eventCount, skippedCount };
    },
  };
}