// WebAssembly ABI bridge (reactor model). One wasm instance = one shard of the swarm.
//
//   alloc(len)/dealloc(ptr,len)              linear-memory scratch for the host
//   spawnDevices(count,seed,w,h) -> renderPtr   create this shard's devices
//   setBeacons(ptr,count)                    copy beacon x/y pairs (host → shard)
//   tick(interfere) -> steps                 advance every device one frame
//
// After spawn, the host caches `renderPtr` and reads `count × [x, y, stateId]`
// Float32s from it each frame (stable — `tick` never reallocates). Ints cross as
// Int32, positions as Float32.

@inline(__always)
func wasmAddress(_ pointer: UnsafeMutableRawPointer) -> Int32 {
    Int32(truncatingIfNeeded: Int(bitPattern: pointer))
}

@inline(__always)
func pointer(fromWasm value: Int32) -> UnsafeMutableRawPointer? {
    UnsafeMutableRawPointer(bitPattern: UInt(UInt32(bitPattern: value)))
}

@_expose(wasm, "alloc")
@_cdecl("alloc")
func alloc(_ len: Int32) -> Int32 {
    let raw = UnsafeMutableRawPointer.allocate(byteCount: max(Int(len), 1), alignment: 4)
    return wasmAddress(raw)
}

@_expose(wasm, "dealloc")
@_cdecl("dealloc")
func dealloc(_ ptr: Int32, _ len: Int32) {
    pointer(fromWasm: ptr)?.deallocate()
}

@_expose(wasm, "spawnDevices")
@_cdecl("spawnDevices")
func spawnDevices(_ count: Int32, _ seed: Int32, _ width: Float, _ height: Float) -> Int32 {
    Swarm.spawn(count: count, seed: UInt32(bitPattern: seed), width: width, height: height)
}

@_expose(wasm, "setBeacons")
@_cdecl("setBeacons")
func setBeacons(_ ptr: Int32, _ count: Int32) {
    let n = max(0, Int(count))
    var xs = [Float](repeating: 0, count: n)
    var ys = [Float](repeating: 0, count: n)
    if n > 0, let raw = pointer(fromWasm: ptr) {
        let f = raw.assumingMemoryBound(to: Float.self)
        var j = 0
        while j < n { xs[j] = f[j * 2]; ys[j] = f[j * 2 + 1]; j += 1 }
    }
    Swarm.beaconsX = xs
    Swarm.beaconsY = ys
}

@_expose(wasm, "tick")
@_cdecl("tick")
func tick(_ interfere: Int32) -> Int32 {
    Swarm.tick(interfere: interfere != 0)
}
