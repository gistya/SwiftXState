// Verify the XState swarm behaves like the Swift one, and measure per-device cost.
import { performance } from "node:perf_hooks";
import { Shard, STATE } from "./swarm.mjs";

const N = 4000, W = 1040, H = 600;
const shard = new Shard(N, 12345, W, H);
shard.setBeacons([200, 160, 800, 160, 520, 300, 700, 460]);

const names = ["patrol", "seek", "sample", "evade", "sleep"];
const hist = () => { const h = [0, 0, 0, 0, 0]; for (let i = 0; i < N; i++) h[shard.render[i * 3 + 2] | 0]++; return h; };

shard.tick(0);
const before = shard.render.slice();
let steps = 0;
const t0 = performance.now();
for (let f = 0; f < 600; f++) steps += shard.tick(0);
const ms = performance.now() - t0;

let moved = 0;
for (let i = 0; i < N; i++) if (Math.abs(shard.render[i * 3] - before[i * 3]) > 0.01 || Math.abs(shard.render[i * 3 + 1] - before[i * 3 + 1]) > 0.01) moved++;

console.log("moved:", moved, "/", N);
console.log("state histogram:", names.map((n, i) => `${n}=${hist()[i]}`).join("  "));
console.log("steps:", steps, `(~${(steps / N).toFixed(1)}/device over 600 frames)`);
console.log("device-transitions/sec (1 core):", Math.round(steps / (ms / 1000)).toLocaleString());
console.log("peak RSS:", Math.round(process.memoryUsage().rss / 1e6), "MB");

for (let f = 0; f < 3; f++) shard.tick(1);
for (let f = 0; f < 5; f++) shard.tick(0);
console.log("after INTERFERE: evade =", hist()[3]);
