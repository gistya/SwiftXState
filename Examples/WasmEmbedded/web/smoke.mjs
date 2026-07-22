// Headless smoke test: instantiate the Embedded wasm, drive real SwiftXState
// machines through the reactor ABI, assert the transitions/guards/assigns behave.
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const here = dirname(fileURLToPath(import.meta.url));
// eslint-disable-next-line no-eval
(0, eval)(readFileSync(join(here, "loader.js"), "utf8")); // defines createSwiftXStateEngine

const wasm = readFileSync(process.argv[2]);
const eng = await globalThis.createSwiftXStateEngine(new Uint8Array(wasm));

let failures = 0;
function check(label, cond, detail) {
  const ok = !!cond;
  if (!ok) failures++;
  console.log(`${ok ? "✓" : "✗"} ${label}${ok ? "" : "  << " + JSON.stringify(detail)}`);
}
const q = (o) => eng.query(o);
const r = (o) => q(o).result;

// --- catalog ---
const cat = q({ op: "catalog" });
check("catalog ok", cat.ok, cat);
check("catalog lists 5 machines", cat.result.machines.length === 5, cat.result.machines.map((m) => m.id));

// --- toggle: assign counter ---
let s = r({ op: "reset", machine: "toggle" });
check("toggle initial = inactive", s.state === "inactive", s);
check("toggle count = 0", s.context.toggles === 0, s.context);
s = r({ op: "send", machine: "toggle", event: "TOGGLE" });
check("toggle -> active", s.state === "active", s);
check("toggle count = 1", s.context.toggles === 1, s.context);
s = r({ op: "send", machine: "toggle", event: "TOGGLE" });
check("toggle -> inactive", s.state === "inactive", s);
check("toggle count = 2", s.context.toggles === 2, s.context);

// --- traffic: cycle + lap count + panic ---
s = r({ op: "reset", machine: "traffic" });
check("traffic initial = green", s.state === "green", s);
s = r({ op: "send", machine: "traffic", event: "NEXT" }); // yellow
s = r({ op: "send", machine: "traffic", event: "NEXT" }); // red
check("traffic -> red", s.state === "red", s);
check("traffic laps still 0", s.context.laps === 0, s.context);
s = r({ op: "send", machine: "traffic", event: "NEXT" }); // green (+1 lap)
check("traffic -> green (lap complete)", s.state === "green", s);
check("traffic laps = 1", s.context.laps === 1, s.context);
s = r({ op: "send", machine: "traffic", event: "PANIC" });
check("traffic PANIC -> red", s.state === "red", s);

// --- vending: the guard ---
s = r({ op: "reset", machine: "vending" });
check("vending initial = idle", s.state === "idle", s);
const dispenseEnabled = (snap) => snap.events.find((e) => e.name === "DISPENSE")?.enabled;
s = r({ op: "send", machine: "vending", event: "COIN" }); // 1
s = r({ op: "send", machine: "vending", event: "COIN" }); // 2
check("vending 2 credits, DISPENSE disabled", s.context.credits === 2 && dispenseEnabled(s) === false, s);
s = r({ op: "send", machine: "vending", event: "COIN" }); // 3
check("vending 3 credits, DISPENSE enabled", s.context.credits === 3 && dispenseEnabled(s) === true, s);
s = r({ op: "send", machine: "vending", event: "DISPENSE" });
check("vending -> dispensing", s.state === "dispensing", s);
check("vending credits 3-3=0, dispensed=1", s.context.credits === 0 && s.context.dispensed === 1, s.context);
s = r({ op: "send", machine: "vending", event: "TAKE" });
check("vending TAKE (0 credits) -> idle", s.state === "idle", s);

// --- counter: guarded both ways ---
s = r({ op: "reset", machine: "counter" });
const dec0 = s.events.find((e) => e.name === "DEC")?.enabled;
check("counter DEC disabled at 0", dec0 === false, s);
for (let i = 0; i < 12; i++) s = r({ op: "send", machine: "counter", event: "INC" });
check("counter clamps at 10", s.context.value === 10, s.context);
check("counter INC disabled at 10", s.events.find((e) => e.name === "INC")?.enabled === false, s);
s = r({ op: "send", machine: "counter", event: "RESET" });
check("counter RESET -> 0", s.context.value === 0, s.context);

// --- crossing: compound (nested) state value ---
s = r({ op: "reset", machine: "crossing" });
s = r({ op: "send", machine: "crossing", event: "NEXT" }); // yellow
s = r({ op: "send", machine: "crossing", event: "NEXT" }); // red.walk
check("crossing compound state = red.walk", s.state === "red.walk", s);
const pedEnabled = (snap) => snap.events.find((e) => e.name === "PED")?.enabled;
check("crossing PED enabled in walk", pedEnabled(s) === true, s);
s = r({ op: "send", machine: "crossing", event: "PED" }); // red.dontWalk
check("crossing -> red.dontWalk", s.state === "red.dontWalk", s);
check("crossing PED disabled in dontWalk", pedEnabled(s) === false, s);
s = r({ op: "send", machine: "crossing", event: "NEXT" }); // green (+1 crossing)
check("crossing -> green", s.state === "green", s);
check("crossing count = 1", s.context.crossings === 1, s.context);

console.log(`\n${failures === 0 ? "ALL PASS" : failures + " FAILURE(S)"}`);
process.exit(failures === 0 ? 0 : 1);
