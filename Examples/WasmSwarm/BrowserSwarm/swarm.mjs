// The all-JS twin of the Firmware Swarm: the SAME firmware behaviour, but the state
// machine is XState v6 (JS) instead of SwiftXState (Embedded wasm), and the sensing +
// kinematics are the JS ports of Swarm.swift. One Shard = one worker's slice.
//
// v6 note: transition `actions` are effects and can't update context — only entry/exit
// can (returning `{ context }`). So per-tick battery changes live in each state's entry
// and TICK reenters the state to re-run it; the evade countdown lives here in JS (a
// CALM event ends it), which is how you'd model a fixed-duration scatter in XState.
import { createMachine, createActor } from "./vendor/xstate-core.mjs";

export const CRITICAL = 15, FULL = 95, RESTED = 42, EVADE_TICKS = 45;
export const STATE = { patrol: 0, seek: 1, sample: 2, evade: 3, sleep: 4 };

const drainSlow = ({ context }) => ({ context: { battery: Math.max(0, context.battery - 0.03) } });
const drain     = ({ context }) => ({ context: { battery: Math.max(0, context.battery - 0.09) } });
const charge    = ({ context }) => ({ context: { battery: Math.min(100, context.battery + 0.6) } });
const trickle   = ({ context }) => ({ context: { battery: Math.min(100, context.battery + 0.16) } });

export function makeFirmware() {
  return createMachine({
    context: ({ input }) => ({ battery: (input && input.battery) || 100 }),
    initial: "patrol",
    states: {
      patrol: {
        entry: drainSlow,
        on: {
          TICK: [{ target: "sleep", guard: ({ context }) => context.battery < CRITICAL }, { target: "patrol", reenter: true }],
          DETECT: "seek",
          INTERFERE: "evade",
        },
      },
      seek: {
        entry: drain,
        on: {
          TICK: [{ target: "sleep", guard: ({ context }) => context.battery < CRITICAL }, { target: "seek", reenter: true }],
          ARRIVE: "sample",
          LOSE: "patrol",
          INTERFERE: "evade",
        },
      },
      sample: {
        entry: charge,
        on: {
          TICK: [{ target: "patrol", guard: ({ context }) => context.battery >= FULL }, { target: "sample", reenter: true }],
          LOSE: "patrol",
          INTERFERE: "evade",
        },
      },
      evade: {
        entry: drain,
        on: {
          TICK: { target: "evade", reenter: true },
          CALM: "patrol",
          INTERFERE: { target: "evade", reenter: true },
        },
      },
      sleep: {
        entry: trickle,
        on: {
          TICK: [{ target: "patrol", guard: ({ context }) => context.battery >= RESTED }, { target: "sleep", reenter: true }],
          INTERFERE: "evade",
        },
      },
    },
  });
}

// Reused event objects — allocating one per send would dwarf the real cost.
const TICK = { type: "TICK" }, DETECT = { type: "DETECT" }, ARRIVE = { type: "ARRIVE" };
const LOSE = { type: "LOSE" }, INTERFERE = { type: "INTERFERE" }, CALM = { type: "CALM" };

// Sensing radii (world units == canvas px) — identical to Swarm.swift.
const DETECT_R = 74, ARRIVE_R = 13, LOSE_R = 150;

function frand(d) { let s = d.rng >>> 0; s ^= s << 13; s ^= s >>> 17; s ^= s << 5; d.rng = s >>> 0; return (d.rng & 0xFFFFFF) / 0x1000000; }

export class Shard {
  constructor(count, seed, width, height) {
    this.w = width; this.h = height;
    this.machine = makeFirmware();
    this.beaconsX = []; this.beaconsY = [];
    this.render = new Float32Array(count * 3);
    this.dev = new Array(count);
    for (let i = 0; i < count; i++) {
      const d = { x: 0, y: 0, vx: 0, vy: 0, rng: ((seed + i * 2654435761) >>> 0) | 1, evade: 0, actor: null };
      const battery = 45 + frand(d) * 55;
      d.x = frand(d) * width; d.y = frand(d) * height;
      d.vx = (frand(d) - 0.5) * 1.0; d.vy = (frand(d) - 0.5) * 1.0;
      d.actor = createActor(this.machine, { input: { battery } }).start();
      this.dev[i] = d;
    }
  }

  setBeacons(arr) {
    const n = arr.length / 2;
    this.beaconsX.length = n; this.beaconsY.length = n;
    for (let j = 0; j < n; j++) { this.beaconsX[j] = arr[j * 2]; this.beaconsY[j] = arr[j * 2 + 1]; }
  }

  nearest(x, y) {
    let best = 1e30, bx = 0, by = 0;
    const m = this.beaconsX.length;
    for (let j = 0; j < m; j++) {
      const ddx = this.beaconsX[j] - x, ddy = this.beaconsY[j] - y, d2 = ddx * ddx + ddy * ddy;
      if (d2 < best) { best = d2; bx = ddx; by = ddy; }
    }
    return [bx, by, Math.sqrt(best)];
  }

  tick(interfere) {
    let steps = 0;
    const buf = this.render, n = this.dev.length;
    for (let i = 0; i < n; i++) {
      const d = this.dev[i], a = d.actor;
      const [dx, dy, dist] = this.nearest(d.x, d.y);
      const sid = STATE[a.getSnapshot().value];

      if (interfere) { a.send(INTERFERE); d.evade = 0; steps++; }
      else if (sid === 0) { if (dist < DETECT_R) { a.send(DETECT); steps++; } }
      else if (sid === 1) { if (dist < ARRIVE_R) { a.send(ARRIVE); steps++; } else if (dist > LOSE_R) { a.send(LOSE); steps++; } }
      else if (sid === 2) { if (dist > LOSE_R) { a.send(LOSE); steps++; } }
      else if (sid === 3) { if (d.evade >= EVADE_TICKS) { a.send(CALM); d.evade = 0; steps++; } else d.evade++; }
      a.send(TICK); steps++;

      const ns = STATE[a.getSnapshot().value];
      this.move(d, ns, dx, dy, dist);
      buf[i * 3] = d.x; buf[i * 3 + 1] = d.y; buf[i * 3 + 2] = ns;
    }
    return steps;
  }

  move(d, state, dx, dy, dist) {
    if (state === 0) {
      d.vx += (frand(d) - 0.5) * 0.5; d.vy += (frand(d) - 0.5) * 0.5;
      const s = Math.hypot(d.vx, d.vy); if (s > 0.95) { d.vx = d.vx / s * 0.95; d.vy = d.vy / s * 0.95; }
    } else if (state === 1) {
      if (dist > 0.001) { d.vx = dx / dist * 2.0; d.vy = dy / dist * 2.0; }
    } else if (state === 2) {
      d.vx *= 0.72; d.vy *= 0.72; d.vx += (frand(d) - 0.5) * 0.25; d.vy += (frand(d) - 0.5) * 0.25;
    } else if (state === 3) {
      const ax = d.x - this.w * 0.5, ay = d.y - this.h * 0.5, m = Math.hypot(ax, ay);
      if (m > 0.001) { d.vx = ax / m * 3.1; d.vy = ay / m * 3.1; } else { d.vx = 3.1; d.vy = 0; }
    } else { d.vx *= 0.9; d.vy *= 0.9; }
    d.x += d.vx; d.y += d.vy;
    if (d.x < 0) d.x += this.w; else if (d.x >= this.w) d.x -= this.w;
    if (d.y < 0) d.y += this.h; else if (d.y >= this.h) d.y -= this.h;
  }
}
