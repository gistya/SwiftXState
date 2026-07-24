// Reactor entry point (intentionally empty). The host calls `_initialize` once, then
// drives everything through the exported functions in Bridge.swift. Swarm state lives
// in `Swarm`'s statics so it initialises lazily, not in a `main()` that never runs.
