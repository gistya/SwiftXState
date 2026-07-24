// Headless scaling of the XState.js swarm across cores — the JS counterpart of
// ../../bench/swarm-scale.mjs, so the two are directly comparable. Each Node worker
// owns a shard of XState actors; we report aggregate device-transitions/sec.
//
//   node bench/swarm-scale.mjs [devicesPerShard] [frames] [subticks]
import { Worker, isMainThread, parentPort, workerData } from "node:worker_threads";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { performance } from "node:perf_hooks";

const self = fileURLToPath(import.meta.url);

if (!isMainThread) {
  const { perShard, frames, subticks } = workerData;
  const { Shard } = await import(join(dirname(self), "..", "swarm.mjs"));
  const shard = new Shard(perShard, 1234 + perShard, 1040, 600);
  shard.setBeacons([200, 160, 800, 160, 520, 300, 700, 460]);
  for (let i = 0; i < 20; i++) shard.tick(0); // warmup
  parentPort.postMessage("ready");
  parentPort.once("message", () => {
    let steps = 0;
    const t0 = performance.now();
    for (let f = 0; f < frames; f++) for (let s = 0; s < subticks; s++) steps += shard.tick(0);
    parentPort.postMessage({ steps, ms: performance.now() - t0, rss: process.memoryUsage().rss });
  });
} else {
  const perShard = Number(process.argv[2] || 3000);
  const frames = Number(process.argv[3] || 200);
  const subticks = Number(process.argv[4] || 4);
  const LEVELS = [1, 2, 4, 8];
  const fmt = (n) => Math.round(n).toLocaleString("en-US");

  async function level(W) {
    const ws = Array.from({ length: W }, () => {
      const w = new Worker(self, { workerData: { perShard, frames, subticks }, resourceLimits: { maxOldGenerationSizeMb: 3072 } });
      return { w, ready: new Promise((r) => w.once("message", r)) };
    });
    await Promise.all(ws.map((x) => x.ready));
    const t0 = performance.now();
    const res = await Promise.all(ws.map((x) => new Promise((r) => { x.w.once("message", r); x.w.postMessage("go"); })));
    const wall = performance.now() - t0;
    await Promise.all(ws.map((x) => x.w.terminate()));
    const steps = res.reduce((a, r) => a + r.steps, 0);
    const rss = Math.max(...res.map((r) => r.rss)); // worker rss == whole-process rss; take the max, don't sum
    return { W, devices: W * perShard, aggregate: steps / (wall / 1000), rssMB: rss / 1e6 };
  }

  console.log(`\nBrowserSwarm (XState.js) scaling — actor shards across worker threads`);
  console.log(`Node ${process.version} · ${fmt(perShard)} devices/shard · ${frames} frames × ${subticks} subticks\n`);
  console.log("workers    devices      device-transitions/sec    scaling   per-core       ~RSS");
  console.log("-".repeat(84));
  let base = null;
  for (const W of LEVELS) {
    const r = await level(W);
    if (base === null) base = r.aggregate;
    console.log(
      String(r.W).padEnd(9) + fmt(r.devices).padStart(9) + fmt(r.aggregate).padStart(24) +
      "    " + (r.aggregate / base).toFixed(2).padStart(5) + "×" + fmt(r.aggregate / r.W).padStart(12) +
      fmt(r.rssMB).padStart(8) + " MB"
    );
  }
  console.log();
}
