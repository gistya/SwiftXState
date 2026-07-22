// Parallel scaling of Embedded-wasm SwiftXState across CPU cores.
//
// Embedded Swift can't target wasm THREADS (the -threads-embedded SDK ships no
// embedded stdlib for the threads triple; threads need the full ~7 MB stdlib). And
// a single machine's `step` is a sequential reducer — no intra-machine parallelism.
// The parallelism you CAN get is many INDEPENDENT machines: run N single-threaded
// wasm instances (each its own linear memory) on N worker threads. No shared memory,
// no threads SDK. This measures how that scales.
//
//   node parallel.mjs [transitionsPerWorker] [workerCounts]
import { Worker, isMainThread, parentPort } from "node:worker_threads";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { performance } from "node:perf_hooks";

const self = fileURLToPath(import.meta.url);
const here = dirname(self);
const WASM = join(here, "..", "dist", "WasmXStateDemo.wasm");
const LOADER = join(here, "..", "web", "loader.js");

if (!isMainThread) {
  // Worker: its own wasm instance (independent memory), single-threaded.
  (0, eval)(readFileSync(LOADER, "utf8"));
  const eng = await globalThis.createSwiftXStateEngine(new Uint8Array(readFileSync(WASM)));
  const benchRun = eng.exports.benchRun;
  benchRun(200_000); // warmup
  parentPort.postMessage({ ready: true });
  parentPort.on("message", (n) => {
    const t0 = performance.now();
    const chk = BigInt.asIntN(64, benchRun(n));
    parentPort.postMessage({ ms: performance.now() - t0, chk: chk.toString() });
  });
} else {
  const ITER = Number(process.argv[2] || 2_000_000);
  const LEVELS = (process.argv[3] || "1,2,4,6,8,10").split(",").map(Number);
  const fmt = (n) => Number(n).toLocaleString("en-US", { maximumFractionDigits: 0 });

  const spawn = () => {
    const w = new Worker(self);
    return { w, ready: new Promise((res) => w.once("message", res)) };
  };
  const runOnce = (w, n) => new Promise((res) => { w.once("message", res); w.postMessage(n); });

  async function level(W) {
    const ws = Array.from({ length: W }, spawn);
    await Promise.all(ws.map((x) => x.ready));
    let bestWall = Infinity, chk, chkOk;
    for (let r = 0; r < 3; r++) {
      const t0 = performance.now();
      const results = await Promise.all(ws.map((x) => runOnce(x.w, ITER)));
      const wall = performance.now() - t0;   // all W run concurrently → wall ≈ slowest worker
      if (wall < bestWall) bestWall = wall;
      chk = results[0].chk;
      chkOk = results.every((rr) => rr.chk === chk);
    }
    await Promise.all(ws.map((x) => x.w.terminate()));
    return { W, agg: (W * ITER) / (bestWall / 1000), chk, chkOk };
  }

  console.log(`\nParallel scaling — independent Embedded-wasm SwiftXState instances (own memory each)`);
  console.log(`Node ${process.version} · ${fmt(ITER)} transitions/worker · 1 KB context · median-of-3\n`);
  console.log(pad("workers", 9) + padL("aggregate t/s", 18) + padL("scaling", 10) + padL("per-worker t/s", 18) + padL("chk", 6));
  console.log("-".repeat(61));
  let base = null;
  for (const W of LEVELS) {
    const x = await level(W);
    if (base === null) base = x.agg;
    console.log(pad(String(W), 9) + padL(fmt(x.agg), 18) + padL((x.agg / base).toFixed(2) + "×", 10) + padL(fmt(x.agg / W), 18) + padL(x.chkOk ? "✓" : "✗", 6));
  }
  console.log();
  function pad(s, w) { return String(s).padEnd(w); }
  function padL(s, w) { return String(s).padStart(w); }
}
