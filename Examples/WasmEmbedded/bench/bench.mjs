// Transitions-per-second benchmark: Embedded-Swift SwiftXState (wasm) vs XState v6
// (JS, current commit) — same machine, same 1 KB context, same host (this Node/V8).
//
//   node bench.mjs [iterationsPerRound] [rounds]
//
// Each engine runs in its OWN child process (isolated heap + GC, raised memory) so
// one engine's allocation churn can't skew another's timing. Both loop entirely in
// their own runtime — Swift inside wasm (benchRun), XState inside JS — with no
// per-step boundary crossing. Checksums must match before any timing is trusted.
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { spawnSync } from "node:child_process";
import { gzipSync } from "node:zlib";

const here = dirname(fileURLToPath(import.meta.url));
const ITER = Number(process.argv[2] || 1_000_000);
const ROUNDS = Number(process.argv[3] || 7);
const WASM = join(here, "..", "dist", "WasmXStateDemo.wasm");
const worker = join(here, "worker.mjs");

const engines = ["swift", "transition", "nextsnapshot", "actor"];
// XState's pure functional API retains O(n) memory per call in alpha.21 (throughput
// degrades as the heap fills), so it can't run a long loop — cap it. Its rate is
// already generous at this size; the O(1) actor path is the fair real-world number.
const PURE_CAP = 100_000;
const capped = (e) => (e === "transition" || e === "nextsnapshot") ? Math.min(ITER, PURE_CAP) : ITER;
const fmt = (n) => Number(n).toLocaleString("en-US", { maximumFractionDigits: 0 });
const pad = (s, w) => String(s).padEnd(w);
const padL = (s, w) => String(s).padStart(w);

console.log(`\nSwiftXState (Embedded wasm) vs XState v6 — up to ${fmt(ITER)} transitions/round × ${ROUNDS} rounds`);
console.log(`Node ${process.version} · 1 KB context (256 × Int32) copied every transition · isolated processes\n`);

const results = [];
for (const e of engines) {
  const n = capped(e);
  process.stdout.write(`  running ${pad(e, 14)} (${fmt(n)}) …`);
  const r = spawnSync(process.execPath, ["--max-old-space-size=4096", worker, e, n, ROUNDS], { encoding: "utf8", maxBuffer: 1 << 24 });
  if (r.status !== 0) {
    const why = (r.stderr || "").split("\n").find((l) => /Error|memory|heap/i.test(l)) || `exit ${r.status}`;
    console.log(` FAILED: ${why.trim().slice(0, 80)}`);
    results.push(null);
    continue;
  }
  const res = JSON.parse(r.stdout.trim().split("\n").pop());
  console.log(` ${fmt(res.tpsMedian)} t/s`);
  results.push(res);
}

const ok = results.filter(Boolean);
console.log();
// Correctness: engines that ran the SAME iteration count must produce the same
// checksum (they can't be compared across different N). Prove equal work within
// each N-group — most importantly the two O(1) engines that ran the full loop.
const groups = new Map();
for (const r of ok) { const g = groups.get(r.iters) || []; g.push(r); groups.set(r.iters, g); }
let allAgree = true;
for (const [iters, grp] of groups) {
  const ref = grp[0].chk;
  const bad = grp.filter((r) => r.chk !== ref);
  if (bad.length) allAgree = false;
  const who = grp.map((r) => r.engine).join(" = ");
  console.log(`checksum @ ${fmt(iters)}: ${ref}  ${bad.length ? "✗ MISMATCH (" + bad.map((b) => b.engine).join(", ") + ")" : "✓ " + who}`);
}
console.log(allAgree ? "→ all engines that ran the same N produced identical context (equal work verified)\n" : "→ CHECKSUM MISMATCH — results not comparable\n");

console.log(pad("engine", 38) + padL("iters", 11) + padL("transitions/sec", 18) + padL("ns/txn", 11) + padL("best t/s", 14));
console.log("-".repeat(92));
for (const r of results) {
  if (!r) continue;
  const note = (r.engine === "transition" || r.engine === "nextsnapshot") ? " *" : "";
  console.log(pad(r.label + note, 38) + padL(fmt(r.iters), 11) + padL(fmt(r.tpsMedian), 18) + padL(r.nsMedian.toFixed(1), 11) + padL(fmt(r.tpsBest), 14));
}
if (byIdHas(results, "transition") || byIdHas(results, "nextsnapshot")) {
  console.log(`\n * pure functional API retains O(n) memory in alpha.21 (throughput degrades as N grows);`);
  console.log(`   capped at ${fmt(PURE_CAP)} and measured at its most favorable size. The actor path is O(1).`);
}
function byIdHas(list, id) { return list.some((r) => r && r.engine === id); }

const byId = Object.fromEntries(ok.map((r) => [r.engine, r]));
if (byId.swift && byId.transition) {
  const x = byId.swift.tpsMedian / byId.transition.tpsMedian;
  console.log(`\nSwift step vs XState transition() [engine-to-engine]:  ${x.toFixed(2)}× ${x >= 1 ? "faster" : "slower"}`);
}
if (byId.swift && byId.actor) {
  const x = byId.swift.tpsMedian / byId.actor.tpsMedian;
  console.log(`Swift step vs XState actor.send() [real-world app]:    ${x.toFixed(2)}× ${x >= 1 ? "faster" : "slower"}`);
}

// ---------- size table ----------
const wasm = readFileSync(WASM);
const wasmGz = gzipSync(wasm).length;
let xstateMin = null;
try { xstateMin = readFileSync(join(here, "vendor", "xstate-core.min.mjs")); } catch {}
console.log("\nModule size (the other half of the story):");
console.log(pad("artifact", 42) + padL("raw", 12) + padL("gzip", 12));
console.log("-".repeat(66));
console.log(pad("SwiftXState Embedded wasm", 42) + padL(fmt(wasm.length), 12) + padL(fmt(wasmGz), 12));
if (xstateMin) {
  const mg = gzipSync(xstateMin).length;
  console.log(pad("XState v6 core (esbuild --minify)", 42) + padL(fmt(xstateMin.length), 12) + padL(fmt(mg), 12));
  console.log(`\nXState minified = ${(xstateMin.length / wasm.length * 100).toFixed(1)}% of the wasm raw, ${(mg / wasmGz * 100).toFixed(1)}% gzipped.`);
}
console.log();
