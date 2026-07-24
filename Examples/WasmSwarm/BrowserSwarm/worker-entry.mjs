// BrowserSwarm worker: one shard of XState.js machines. Same protocol as the wasm
// swarm's worker (init / tick → packed [x,y,state] Float32 buffer), so the main-thread
// UI is byte-for-byte the same — only the engine differs. esbuild bundles this file
// (with XState + swarm.mjs) into one self-contained script that the page inlines.
import { Shard } from "./swarm.mjs";

let shard = null;
self.onmessage = (e) => {
  const m = e.data;
  if (m.type === "init") {
    shard = new Shard(m.count, m.seed, m.w, m.h);
    self.postMessage({ type: "ready" });
  } else if (m.type === "tick") {
    shard.setBeacons(m.beacons);
    const sub = (m.subticks | 0) || 1;
    let steps = 0;
    for (let k = 0; k < sub; k++) steps += shard.tick(k === 0 ? m.interfere : 0);
    const out = shard.render.slice();
    self.postMessage({ type: "frame", buf: out.buffer, steps, count: shard.dev.length }, [out.buffer]);
  }
};
