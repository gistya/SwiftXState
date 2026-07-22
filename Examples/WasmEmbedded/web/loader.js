// SwiftXState Embedded-wasm loader — shared by the Node smoke test and inlined into
// the self-contained index.html at build time. Deliberately dependency-free: needs
// only `WebAssembly` and (for the base64 path) `atob`/`Buffer`. UTF-8 is hand-rolled.
//
// Attaches two globals:
//   createSwiftXStateEngine(bytes)  -> Promise<{ query(obj) -> obj }>
//   sxsBase64ToBytes(b64)           -> Uint8Array
(function (root) {
  "use strict";

  function sxsBase64ToBytes(b64) {
    if (typeof atob === "function") {
      var bin = atob(b64);
      var bytes = new Uint8Array(bin.length);
      for (var i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
      return bytes;
    }
    return new Uint8Array(Buffer.from(b64, "base64")); // Node
  }

  function utf8Encode(str) {
    var out = [];
    for (var i = 0; i < str.length; i++) {
      var c = str.charCodeAt(i);
      if (c < 0x80) {
        out.push(c);
      } else if (c < 0x800) {
        out.push(0xC0 | (c >> 6), 0x80 | (c & 0x3F));
      } else if (c >= 0xD800 && c <= 0xDBFF) {
        var c2 = str.charCodeAt(++i);
        var cp = 0x10000 + ((c & 0x3FF) << 10) + (c2 & 0x3FF);
        out.push(0xF0 | (cp >> 18), 0x80 | ((cp >> 12) & 0x3F),
                 0x80 | ((cp >> 6) & 0x3F), 0x80 | (cp & 0x3F));
      } else {
        out.push(0xE0 | (c >> 12), 0x80 | ((c >> 6) & 0x3F), 0x80 | (c & 0x3F));
      }
    }
    return Uint8Array.from(out);
  }

  function utf8Decode(bytes) {
    var out = "";
    for (var i = 0; i < bytes.length;) {
      var b = bytes[i++];
      if (b < 0x80) {
        out += String.fromCharCode(b);
      } else if (b < 0xE0) {
        out += String.fromCharCode(((b & 0x1F) << 6) | (bytes[i++] & 0x3F));
      } else if (b < 0xF0) {
        out += String.fromCharCode(((b & 0x0F) << 12) | ((bytes[i++] & 0x3F) << 6) | (bytes[i++] & 0x3F));
      } else {
        var cp = ((b & 0x07) << 18) | ((bytes[i++] & 0x3F) << 12) |
                 ((bytes[i++] & 0x3F) << 6) | (bytes[i++] & 0x3F);
        cp -= 0x10000;
        out += String.fromCharCode(0xD800 + (cp >> 10), 0xDC00 + (cp & 0x3FF));
      }
    }
    return out;
  }

  // Minimal wasi_snapshot_preview1 shim. Embedded Swift reaches only a handful of
  // these (time, randomness, stdout/stderr for traps/prints). We implement the ones
  // that must write real data into linear memory; anything else returns success and
  // is never exercised. Memory is read lazily — the `memory` export doesn't exist
  // until instantiation resolves.
  function makeWASI(getExports) {
    function dv() { return new DataView(getExports().memory.buffer); }
    function u8() { return new Uint8Array(getExports().memory.buffer); }
    var real = {
      clock_time_get: function (id, precision, out) {
        dv().setBigUint64(out >>> 0, BigInt(Date.now()) * 1000000n, true);
        return 0;
      },
      clock_res_get: function (id, out) { dv().setBigUint64(out >>> 0, 1000n, true); return 0; },
      random_get: function (ptr, len) {
        var b = u8(); ptr = ptr >>> 0;
        for (var i = 0; i < len; i++) b[ptr + i] = (Math.random() * 256) & 0xFF;
        return 0;
      },
      fd_write: function (fd, iovs, n, outWritten) {
        var d = dv(), b = u8(), total = 0, s = "";
        iovs = iovs >>> 0;
        for (var i = 0; i < n; i++) {
          var p = d.getUint32(iovs + i * 8, true) >>> 0;
          var l = d.getUint32(iovs + i * 8 + 4, true) >>> 0;
          s += utf8Decode(b.subarray(p, p + l));
          total += l;
        }
        d.setUint32(outWritten >>> 0, total, true);
        if (s && typeof console !== "undefined") console.log("[wasm]", s.replace(/\n+$/, ""));
        return 0;
      },
      args_sizes_get: function (a, b) { var d = dv(); d.setUint32(a >>> 0, 0, true); d.setUint32(b >>> 0, 0, true); return 0; },
      environ_sizes_get: function (a, b) { var d = dv(); d.setUint32(a >>> 0, 0, true); d.setUint32(b >>> 0, 0, true); return 0; },
      proc_exit: function (code) { throw new Error("wasm called proc_exit(" + code + ")"); }
    };
    return new Proxy(real, { get: function (t, k) { return (k in t) ? t[k] : function () { return 0; }; } });
  }

  async function createSwiftXStateEngine(bytes) {
    var exportsRef = { current: null };
    var result = await WebAssembly.instantiate(bytes, {
      wasi_snapshot_preview1: makeWASI(function () { return exportsRef.current; })
    });
    var wasm = result.instance.exports;
    exportsRef.current = wasm;
    if (typeof wasm._initialize === "function") wasm._initialize(); // run Swift ctors once

    function mem() { return new Uint8Array(wasm.memory.buffer); }

    function writeBytes(b) {
      var ptr = wasm.alloc(b.length) >>> 0;
      mem().set(b, ptr);                 // re-read after alloc (growth detaches)
      return ptr;
    }

    function readResult(resPtr) {
      resPtr = resPtr >>> 0;
      var m = mem();
      var len = (m[resPtr] | (m[resPtr + 1] << 8) | (m[resPtr + 2] << 16) | (m[resPtr + 3] << 24)) >>> 0;
      var start = resPtr + 4;
      var text = utf8Decode(m.subarray(start, start + len));
      wasm.dealloc(resPtr, 4 + len);
      return text;
    }

    // JSON in, JSON out. Synchronous under the hood.
    function query(request) {
      var reqBytes = utf8Encode(JSON.stringify(request));
      var reqPtr = writeBytes(reqBytes);
      var resPtr;
      try {
        resPtr = wasm.query(reqPtr, reqBytes.length);
      } finally {
        wasm.dealloc(reqPtr, reqBytes.length);
      }
      return JSON.parse(readResult(resPtr));
    }

    return { query: query, exports: wasm };
  }

  root.createSwiftXStateEngine = createSwiftXStateEngine;
  root.sxsBase64ToBytes = sxsBase64ToBytes;
})(typeof globalThis !== "undefined" ? globalThis : this);
