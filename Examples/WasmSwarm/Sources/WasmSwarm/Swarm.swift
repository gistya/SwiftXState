import SwiftXState

// One shard of the swarm: an array of devices, each an independent firmware snapshot,
// plus the sensing + kinematics that turn "what state am I in" into motion. The
// discrete BEHAVIOR is SwiftXState's job (Brain.swift); this file is the body around
// the brain — position, velocity, and the beacon sensing that produces events.
//
// Everything here is plain, Foundation-free Swift: a per-device xorshift RNG, Float
// math, and one shared `MachineLogic` (all devices run the same firmware).

struct Device {
    var x: Float = 0
    var y: Float = 0
    var vx: Float = 0
    var vy: Float = 0
    var rng: UInt32 = 1
    var snapshot: MachineSnapshot<BrainContext>
}

@inline(__always) func xorshift(_ s: inout UInt32) -> UInt32 {
    s ^= s << 13; s ^= s >> 17; s ^= s << 5; return s
}
@inline(__always) func frand(_ s: inout UInt32) -> Float {
    Float(xorshift(&s) & 0xFF_FFFF) / Float(0x100_0000)   // 0…1
}

enum Swarm {
    nonisolated(unsafe) static var logic = MachineLogic(machine: makeFirmware())
    nonisolated(unsafe) static var devices: [Device] = []
    nonisolated(unsafe) static var beaconsX: [Float] = []
    nonisolated(unsafe) static var beaconsY: [Float] = []
    nonisolated(unsafe) static var worldW: Float = 1000
    nonisolated(unsafe) static var worldH: Float = 640
    nonisolated(unsafe) static var render: UnsafeMutablePointer<Float>?
    nonisolated(unsafe) static var renderCount: Int = 0
    nonisolated(unsafe) static var lastSteps: Int32 = 0

    // Reused event values (immutable) so the hot loop doesn't reallocate them.
    static let evTick = Event("TICK")
    static let evDetect = Event("DETECT")
    static let evArrive = Event("ARRIVE")
    static let evLose = Event("LOSE")
    static let evInterfere = Event("INTERFERE")

    // Sensing radii (world units == canvas px).
    static let detectR: Float = 74
    static let arriveR: Float = 13
    static let loseR: Float = 150

    static func spawn(count: Int32, seed: UInt32, width: Float, height: Float) -> Int32 {
        worldW = width
        worldH = height
        let n = max(0, Int(count))
        devices.removeAll(keepingCapacity: false)
        devices.reserveCapacity(n)
        for i in 0..<n {
            var r = (seed &+ UInt32(truncatingIfNeeded: i) &* 2_654_435_761) | 1
            let battery = 45 + frand(&r) * 55   // 45…100, staggered
            var d = Device(snapshot: logic.initialState(input: SendableValue(battery)))
            d.x = frand(&r) * width
            d.y = frand(&r) * height
            d.vx = (frand(&r) - 0.5) * 1.0
            d.vy = (frand(&r) - 0.5) * 1.0
            d.rng = r
            devices.append(d)
        }
        if let old = render { old.deallocate() }
        renderCount = n
        render = UnsafeMutablePointer<Float>.allocate(capacity: max(n, 1) * 3)
        return wasmAddress(UnsafeMutableRawPointer(render!))
    }

    @inline(__always)
    static func nearestBeacon(_ x: Float, _ y: Float) -> (dx: Float, dy: Float, dist: Float) {
        var best: Float = 1e30, bx: Float = 0, by: Float = 0
        var j = 0
        let m = beaconsX.count
        while j < m {
            let ddx = beaconsX[j] - x, ddy = beaconsY[j] - y
            let d2 = ddx * ddx + ddy * ddy
            if d2 < best { best = d2; bx = ddx; by = ddy }
            j += 1
        }
        return (bx, by, best.squareRoot())
    }

    static func tick(interfere: Bool) -> Int32 {
        guard let buf = render else { return 0 }
        var steps: Int32 = 0
        let n = devices.count
        var i = 0
        while i < n {
            var d = devices[i]
            let (dx, dy, dist) = nearestBeacon(d.x, d.y)
            let sid = stateId(of: d.snapshot)

            // One sensing/global event (if any), then the heartbeat.
            if interfere {
                d.snapshot = logic.step(d.snapshot, on: evInterfere); steps += 1
            } else if sid == DeviceState.patrol {
                if dist < detectR { d.snapshot = logic.step(d.snapshot, on: evDetect); steps += 1 }
            } else if sid == DeviceState.seek {
                if dist < arriveR { d.snapshot = logic.step(d.snapshot, on: evArrive); steps += 1 }
                else if dist > loseR { d.snapshot = logic.step(d.snapshot, on: evLose); steps += 1 }
            } else if sid == DeviceState.sample {
                if dist > loseR { d.snapshot = logic.step(d.snapshot, on: evLose); steps += 1 }
            }
            d.snapshot = logic.step(d.snapshot, on: evTick); steps += 1

            let ns = stateId(of: d.snapshot)
            move(&d, state: ns, dx: dx, dy: dy, dist: dist)

            buf[i * 3] = d.x
            buf[i * 3 + 1] = d.y
            buf[i * 3 + 2] = ns
            devices[i] = d
            i += 1
        }
        lastSteps = steps
        return steps
    }

    @inline(__always)
    static func move(_ d: inout Device, state: Float, dx: Float, dy: Float, dist: Float) {
        if state == DeviceState.patrol {
            d.vx += (frand(&d.rng) - 0.5) * 0.5
            d.vy += (frand(&d.rng) - 0.5) * 0.5
            clampSpeed(&d.vx, &d.vy, 0.95)
        } else if state == DeviceState.seek {
            if dist > 0.001 { d.vx = dx / dist * 2.0; d.vy = dy / dist * 2.0 }
        } else if state == DeviceState.sample {
            d.vx *= 0.72; d.vy *= 0.72
            d.vx += (frand(&d.rng) - 0.5) * 0.25
            d.vy += (frand(&d.rng) - 0.5) * 0.25
        } else if state == DeviceState.evade {
            let ax = d.x - worldW * 0.5, ay = d.y - worldH * 0.5
            let m = (ax * ax + ay * ay).squareRoot()
            if m > 0.001 { d.vx = ax / m * 3.1; d.vy = ay / m * 3.1 } else { d.vx = 3.1; d.vy = 0 }
        } else { // sleep
            d.vx *= 0.9; d.vy *= 0.9
        }
        d.x += d.vx; d.y += d.vy
        if d.x < 0 { d.x += worldW } else if d.x >= worldW { d.x -= worldW }
        if d.y < 0 { d.y += worldH } else if d.y >= worldH { d.y -= worldH }
    }

    @inline(__always)
    static func clampSpeed(_ vx: inout Float, _ vy: inout Float, _ maxS: Float) {
        let s = (vx * vx + vy * vy).squareRoot()
        if s > maxS, s > 0.0001 { vx = vx / s * maxS; vy = vy / s * maxS }
    }
}
