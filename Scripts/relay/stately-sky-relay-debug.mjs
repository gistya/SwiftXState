/**
 * Debug relay — same Sky bridge as stately-sky-relay.mjs, with inspection
 * events summarized on the console.
 *
 * Usage:
 *   npm run relay:debug
 *   node stately-sky-relay-debug.mjs
 *   node stately-sky-relay-debug.mjs --verbose
 *   node stately-sky-relay-debug.mjs --filter game-watcher
 */
process.env.RELAY_DEBUG = '1';

const args = process.argv.slice(2);
if (!args.includes('--debug') && !args.includes('-d')) {
  process.argv.push('--debug');
}

await import('./stately-sky-relay.mjs');