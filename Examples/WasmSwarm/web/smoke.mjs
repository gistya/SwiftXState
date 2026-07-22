// Headless test of the swarm ABI: spawn devices, set beacons, tick, read the render
// buffer, and confirm devices move and distribute across firmware states.
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
const here = dirname(fileURLToPath(import.meta.url));
(0, eval)(readFileSync(join(here, "loader.js"), "utf8"));

const eng = await globalThis.createSwiftXStateEngine(new Uint8Array(readFileSync(join(here, "..", "dist", "WasmSwarm.wasm"))));
const x = eng.exports;
const W = 1000, H = 640, COUNT = 4000;

const renderPtr = x.spawnDevices(COUNT, 12345, W, H) >>> 0;
console.log("spawnDevices →", COUNT, "devices, renderPtr", renderPtr);

// beacons
const beacons = [200, 160, 800, 160, 500, 480];
const bytes = beacons.length * 4;
const bptr = x.alloc(bytes) >>> 0;
new Float32Array(x.memory.buffer, bptr, beacons.length).set(beacons);
x.setBeacons(bptr, beacons.length / 2);
x.dealloc(bptr, bytes);
console.log("setBeacons →", beacons.length / 2, "beacons");

function snapshot() {
  const view = new Float32Array(x.memory.buffer, renderPtr, COUNT * 3).slice(); // copy, not live view
  const hist = [0, 0, 0, 0, 0];
  let sx = 0, sy = 0;
  for (let i = 0; i < COUNT; i++) {
    sx += view[i * 3]; sy += view[i * 3 + 1];
    hist[view[i * 3 + 2] | 0]++;
  }
  return { hist, cx: sx / COUNT, cy: sy / COUNT, view };
}

let totalSteps = 0;
x.tick(0);                     // one frame so positions are populated
const before = snapshot();
for (let f = 0; f < 600; f++) totalSteps += x.tick(0);   // ~10s of frames
const after = snapshot();

// how many devices moved?
let moved = 0;
for (let i = 0; i < COUNT; i++) {
  if (Math.abs(after.view[i * 3] - before.view[i * 3]) > 0.01 || Math.abs(after.view[i * 3 + 1] - before.view[i * 3 + 1]) > 0.01) moved++;
}

const names = ["patrol", "seek", "sample", "evade", "sleep"];
console.log("\nafter 600 ticks:");
console.log("  devices moved:", moved, "/", COUNT);
console.log("  total steps:", totalSteps, `(~${(totalSteps / COUNT).toFixed(1)} steps/device)`);
console.log("  state histogram:", names.map((n, i) => `${n}=${after.hist[i]}`).join("  "));

// interference burst → should push many into evade
for (let f = 0; f < 3; f++) x.tick(1);
for (let f = 0; f < 5; f++) x.tick(0);
const evaded = snapshot().hist[3];
console.log("  after INTERFERE: evade =", evaded);

const ok = moved > COUNT * 0.9 && after.hist.filter((h) => h > 0).length >= 3 && evaded > COUNT * 0.5;
console.log("\n" + (ok ? "OK — devices move, states populate, interference scatters" : "✗ unexpected"));
process.exit(ok ? 0 : 1);
