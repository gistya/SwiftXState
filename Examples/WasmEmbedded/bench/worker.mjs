// One engine, one isolated process. Prints a single JSON result line.
//   node --max-old-space-size=4096 worker.mjs <engine> <iter> <rounds>
// engine ∈ swift | transition | nextsnapshot | actor
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { performance } from "node:perf_hooks";
import {
  createMachine, createActor, getInitialSnapshot, getNextSnapshot, transition
} from "./vendor/xstate-core.mjs";

const here = dirname(fileURLToPath(import.meta.url));
const [engine, iterArg, roundsArg] = process.argv.slice(2);
const ITER = Number(iterArg), ROUNDS = Number(roundsArg);

// ---- identical machine (1 KB context, entry-based context update, guard) ----
const N = 256;
function updater({ context }) {
  const counter = context.counter + 1;
  const data = context.data.slice();
  data[counter % N] = counter;
  return { context: { counter, data } };
}
const guard = ({ context }) => context.counter >= 0;
const makeMachine = () => createMachine({
  context: () => ({ counter: 0, data: new Int32Array(N) }),
  initial: "a",
  states: {
    a: { entry: updater, on: { PING: { target: "b", guard } } },
    b: { entry: updater, on: { PING: { target: "a", guard } } }
  }
});
const csJS = (c) => { let s = BigInt(c.counter); for (let i = 0; i < c.data.length; i++) s += BigInt(c.data[i]); return s; };
const PING = { type: "PING" };

const runners = {
  transition(n) {
    const m = makeMachine();
    let s = getInitialSnapshot(m);
    for (let i = 0; i < n; i++) { const r = transition(m, s, PING); s = Array.isArray(r) ? r[0] : r; }
    return csJS(s.context);
  },
  nextsnapshot(n) {
    const m = makeMachine();
    let s = getInitialSnapshot(m);
    for (let i = 0; i < n; i++) s = getNextSnapshot(m, s, PING);
    return csJS(s.context);
  },
  actor(n) {
    const a = createActor(makeMachine()).start();
    for (let i = 0; i < n; i++) a.send(PING);
    return csJS(a.getSnapshot().context);
  }
};

const labels = {
  swift: "SwiftXState step (Embedded wasm)",
  transition: "XState transition() [pure]",
  nextsnapshot: "XState getNextSnapshot() [pure]",
  actor: "XState actor .send() [real-world]"
};

let fn;
if (engine === "swift") {
  (0, eval)(readFileSync(join(here, "..", "web", "loader.js"), "utf8"));
  const bytes = new Uint8Array(readFileSync(join(here, "..", "dist", "WasmXStateDemo.wasm")));
  const eng = await globalThis.createSwiftXStateEngine(bytes);
  const benchRun = eng.exports.benchRun;
  fn = (n) => BigInt.asIntN(64, benchRun(n));
} else {
  fn = runners[engine];
}

fn(Math.min(ITER, 200_000)); // warmup
const times = [];
let chk;
for (let r = 0; r < ROUNDS; r++) {
  const t0 = performance.now();
  chk = fn(ITER);
  times.push(performance.now() - t0);
}
times.sort((a, b) => a - b);
const median = times[Math.floor(times.length / 2)];
const best = times[0];
process.stdout.write(JSON.stringify({
  engine, label: labels[engine], chk: chk.toString(), iters: ITER,
  tpsMedian: ITER / (median / 1000),
  tpsBest: ITER / (best / 1000),
  nsMedian: (median * 1e6) / ITER
}) + "\n");
