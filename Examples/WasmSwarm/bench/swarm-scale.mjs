// Headless scaling of the swarm workload across CPU cores — no rendering, no rAF
// (the browser preview throttles background tabs, so this is the honest measurement).
// Each Node worker owns an independent wasm instance stepping its own shard of
// devices; we scale the shard count with the worker count and report aggregate
// device-transitions per second.
//
//   node swarm-scale.mjs [devicesPerShard] [frames] [subticks]
import { Worker, isMainThread, parentPort, workerData } from "node:worker_threads";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { performance } from "node:perf_hooks";

const self = fileURLToPath(import.meta.url);
const here = dirname(self);
const WASM = join(here, "..", "dist", "WasmSwarm.wasm");
const LOADER = join(here, "..", "web", "loader.js");

if (!isMainThread) {
  const { perShard, frames, subticks } = workerData;
  (0, eval)(readFileSync(LOADER, "utf8"));
  const eng = await globalThis.createSwiftXStateEngine(new Uint8Array(readFileSync(WASM)));
  const x = eng.exports;
  x.spawnDevices(perShard, 1234 + perShard, 1040, 600);
  const b = [200, 160, 800, 160, 520, 300, 700, 460];
  const bp = x.alloc(b.length * 4) >>> 0;
  new Float32Array(x.memory.buffer, bp, b.length).set(b);
  x.setBeacons(bp, b.length / 2);
  x.dealloc(bp, b.length * 4);
  for (let i = 0; i < 20; i++) x.tick(0); // warmup
  parentPort.postMessage("ready");
  parentPort.once("message", () => {
    let steps = 0;
    const t0 = performance.now();
    for (let f = 0; f < frames; f++) for (let s = 0; s < subticks; s++) steps += x.tick(0);
    parentPort.postMessage({ steps, ms: performance.now() - t0 });
  });
} else {
  const perShard = Number(process.argv[2] || 8000);
  const frames = Number(process.argv[3] || 200);
  const subticks = Number(process.argv[4] || 4);
  const LEVELS = [1, 2, 4, 8, 10];
  const fmt = (n) => Math.round(n).toLocaleString("en-US");

  async function level(W) {
    const ws = Array.from({ length: W }, () => {
      const w = new Worker(self, { workerData: { perShard, frames, subticks } });
      return { w, ready: new Promise((r) => w.once("message", r)) };
    });
    await Promise.all(ws.map((x) => x.ready));
    const t0 = performance.now();
    const res = await Promise.all(ws.map((x) => new Promise((r) => { x.w.once("message", r); x.w.postMessage("go"); })));
    const wall = performance.now() - t0;
    await Promise.all(ws.map((x) => x.w.terminate()));
    const steps = res.reduce((a, r) => a + r.steps, 0);
    return { W, devices: W * perShard, aggregate: steps / (wall / 1000) };
  }

  console.log(`\nSwarm scaling — independent device shards across worker threads`);
  console.log(`Node ${process.version} · ${fmt(perShard)} devices/shard · ${frames} frames × ${subticks} subticks · 8-byte context\n`);
  console.log("workers    devices      device-transitions/sec    scaling   per-core");
  console.log("-".repeat(74));
  let base = null;
  for (const W of LEVELS) {
    const r = await level(W);
    if (base === null) base = r.aggregate;
    console.log(
      String(r.W).padEnd(9) + fmt(r.devices).padStart(9) + fmt(r.aggregate).padStart(24) +
      "    " + (r.aggregate / base).toFixed(2).padStart(5) + "×" + fmt(r.aggregate / r.W).padStart(12)
    );
  }
  console.log();
}
