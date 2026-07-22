// Executable entry point (intentionally empty).
//
// This is a wasm *reactor*: the synthesised `main()` never runs. The host calls
// `_initialize()` once after instantiation to run global constructors, then drives
// everything through the exported `query` function (see Bridge.swift).
//
// All engine state therefore lives as `static` members (Engine.sessions) so it
// initialises lazily on first access rather than eagerly in a `main()` that is
// never called.
