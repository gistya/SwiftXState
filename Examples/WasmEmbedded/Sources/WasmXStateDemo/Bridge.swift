// WebAssembly ABI bridge (reactor model).
//
// The module speaks one protocol to the host page:
//
//   • alloc(len)          -> ptr    reserve `len` bytes of linear memory
//   • dealloc(ptr, len)   -> ()     release memory from alloc / a query result
//   • query(ptr, len)     -> resPtr run one JSON request, return a result buffer
//
// Everything crosses as Int32 (no i64/BigInt friction). The request at
// [ptr, ptr+len) is UTF-8 JSON. The result pointer addresses a length-prefixed
// buffer: a little-endian UInt32 length, then that many UTF-8 bytes. The host reads
// the length, copies the bytes, then calls dealloc(resPtr, 4 + length).
//
// Single-threaded wasm: one call runs to completion before the next, so there is no
// concurrency to guard.

@inline(__always)
private func wasmAddress(_ pointer: UnsafeMutableRawPointer) -> Int32 {
    Int32(truncatingIfNeeded: Int(bitPattern: pointer))
}

@inline(__always)
private func pointer(fromWasm value: Int32) -> UnsafeMutableRawPointer? {
    UnsafeMutableRawPointer(bitPattern: UInt(UInt32(bitPattern: value)))
}

@_expose(wasm, "alloc")
@_cdecl("alloc")
func alloc(_ len: Int32) -> Int32 {
    let count = max(Int(len), 1)
    let raw = UnsafeMutableRawPointer.allocate(byteCount: count, alignment: 1)
    return wasmAddress(raw)
}

@_expose(wasm, "dealloc")
@_cdecl("dealloc")
func dealloc(_ ptr: Int32, _ len: Int32) {
    guard let raw = pointer(fromWasm: ptr) else { return }
    raw.deallocate()
}

@_expose(wasm, "query")
@_cdecl("query")
func query(_ ptr: Int32, _ len: Int32) -> Int32 {
    // Copy the request bytes out of linear memory.
    var request = [UInt8]()
    if len > 0, let raw = pointer(fromWasm: ptr) {
        let bytes = raw.assumingMemoryBound(to: UInt8.self)
        request = Array(UnsafeBufferPointer(start: bytes, count: Int(len)))
    }

    let payload = Engine.handle(requestBytes: request)   // [UInt8] UTF-8 JSON

    // Result buffer: [UInt32 little-endian length][payload...].
    let total = 4 + payload.count
    let raw = UnsafeMutableRawPointer.allocate(byteCount: total, alignment: 1)
    let out = raw.assumingMemoryBound(to: UInt8.self)
    let n = UInt32(payload.count)
    out[0] = UInt8(n & 0xFF)
    out[1] = UInt8((n >> 8) & 0xFF)
    out[2] = UInt8((n >> 16) & 0xFF)
    out[3] = UInt8((n >> 24) & 0xFF)
    for i in 0..<payload.count {
        out[4 + i] = payload[i]
    }
    return wasmAddress(raw)
}
