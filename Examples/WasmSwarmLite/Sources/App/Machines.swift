import SwiftXState

// A "lite" swarm of communicating SwiftXState actors — an excitable signal mesh.
//
// Each NODE is its own SwiftXState machine (resting → firing → refractory) invoked as a
// child of one ROUTER machine. Nodes never address each other directly (XState has no
// sibling addressing); instead they talk THROUGH the router using the framework's real
// delivery: a node fires → `sendToParent("FIRED#i")` → the router relays a `PULSE` to each
// of that node's graph-neighbours via `sendTo("n\(j)", …)`. Firing is gated to a per-frame
// `TICK` (broadcast by the router), so excitation spreads exactly one ring per frame — a
// visible travelling wave, built entirely on SwiftXState's spawn + send.

// MARK: - Topology (a bounded 2-D grid, von-Neumann neighbourhood)

struct Topology {
    let w: Int
    let h: Int
    let adj: [[Int]]            // adj[i] = indices of node i's neighbours
    var n: Int { w * h }
    func xy(_ i: Int) -> (Int, Int) { (i % w, i / w) }
    var center: Int { (h / 2) * w + (w / 2) }
}

func makeTopology(w: Int, h: Int) -> Topology {
    func idx(_ x: Int, _ y: Int) -> Int { y * w + x }
    var adj = Array(repeating: [Int](), count: w * h)
    for y in 0..<h {
        for x in 0..<w {
            var ns: [Int] = []
            if x > 0     { ns.append(idx(x - 1, y)) }
            if x < w - 1 { ns.append(idx(x + 1, y)) }
            if y > 0     { ns.append(idx(x, y - 1)) }
            if y < h - 1 { ns.append(idx(x, y + 1)) }
            adj[idx(x, y)] = ns
        }
    }
    return Topology(w: w, h: h, adj: adj)
}

// MARK: - Node machine (one per instance)

struct NodeContext: Sendable, Equatable {
    var charge: Int = 0   // accumulated input; fires on the next TICK once it reaches threshold
    var cool: Int = 0     // refractory frames remaining
}

func makeNode(id: Int, threshold: Int, refractory: Int) -> ResolvedMachine<NodeContext> {
    let chargeUp = assign { (c: inout NodeContext, _: ActionArgs<NodeContext>) in c.charge = min(c.charge + 1, 9) }
    let leak     = assign { (c: inout NodeContext, _: ActionArgs<NodeContext>) in if c.charge > 0 { c.charge -= 1 } }
    let ignite   = assign { (c: inout NodeContext, _: ActionArgs<NodeContext>) in c.charge = 0; c.cool = refractory }
    let coolDown = assign { (c: inout NodeContext, _: ActionArgs<NodeContext>) in c.cool -= 1 }
    let clear    = assign { (c: inout NodeContext, _: ActionArgs<NodeContext>) in c.charge = 0; c.cool = 0 }
    let reset: TransitionInput<NodeContext> = .single(TransitionConfig(target: "resting", actions: [clear]))

    return createMachine(MachineConfig<NodeContext>(
        id: "node\(id)",
        initial: "resting",
        context: NodeContext(),
        states: [
            "resting": StateNodeConfig(on: [
                // PULSE only accumulates — firing is decided on TICK, which is what makes the
                // wave spread one ring per frame instead of cascading in a single step.
                "PULSE": .single(TransitionConfig(target: nil, actions: [chargeUp])),
                "STIMULATE": .target("firing"),               // external kick (a user click)
                "TICK": .multiple([
                    TransitionConfig(target: "firing", guard: .inline { $0.context.charge >= threshold }),
                    TransitionConfig(target: nil, actions: [leak]),
                ]),
                "RESET": reset,
            ]),
            "firing": StateNodeConfig(
                on: [
                    "TICK": .target("refractory"),            // the flash lasts one frame
                    "RESET": reset,
                ],
                // On entry: reset charge, arm the refractory timer, and tell the router we fired
                // so it can pulse our neighbours. This is the real inter-actor message.
                entry: [ignite, .sendToParent(Event("FIRED#\(id)"))]
            ),
            "refractory": StateNodeConfig(on: [
                // Deaf to PULSE while cooling down — this is what carves a clean wavefront.
                "TICK": .multiple([
                    TransitionConfig(target: "resting", guard: .inline { $0.context.cool <= 1 }, actions: [clear]),
                    TransitionConfig(target: nil, actions: [coolDown]),
                ]),
                "RESET": reset,
            ]),
        ]
    ))
}

// MARK: - Router machine (parent — invokes every node, relays between them)

struct RouterContext: Sendable, Equatable {
    var fires: Int = 0
    var justFired: [Int] = []   // node indices that fired since the last STEP — the render feed
}

func makeRouter(_ topo: Topology, threshold: Int, refractory: Int) -> ResolvedMachine<RouterContext> {
    var on: [String: TransitionInput<RouterContext>] = [:]
    var invokes: [InvokeConfig<RouterContext>] = []

    // One TICK broadcast per frame advances every node (and gates firing). Clear the
    // render feed first; this step's firings will re-accumulate as FIRED#i arrive.
    on["STEP"] = .single(TransitionConfig(actions: [
        enqueueActions { b in
            b.enqueue(assign { (c: inout RouterContext, _: ActionArgs<RouterContext>) in c.justFired = [] })
            for i in 0..<topo.n { b.sendTo("n\(i)", Event("TICK")) }
        },
    ]))
    // Reset the whole field.
    on["RESET"] = .single(TransitionConfig(actions: [
        enqueueActions { b in
            b.enqueue(assign { (c: inout RouterContext, _: ActionArgs<RouterContext>) in c.fires = 0 })
            for i in 0..<topo.n { b.sendTo("n\(i)", Event("RESET")) }
        },
    ]))

    for i in 0..<topo.n {
        let idx = i
        let neighbours = topo.adj[i]
        // A node fired → count it, note it for the renderer, and relay a PULSE to each
        // neighbour. Child → parent → children — the whole point of the demo.
        on["FIRED#\(i)"] = .single(TransitionConfig(actions: [
            enqueueActions { b in
                b.enqueue(assign { (c: inout RouterContext, _: ActionArgs<RouterContext>) in c.fires += 1; c.justFired.append(idx) })
                for j in neighbours { b.sendTo("n\(j)", Event("PULSE")) }
            },
        ]))
        // External stimulation of a specific node (routed from a user click).
        on["STIM#\(i)"] = .single(TransitionConfig(actions: [sendTo("n\(i)", Event("STIMULATE"))]))
        // Each node is a child actor of the router.
        invokes.append(InvokeConfig(
            id: "n\(i)",
            src: .machine(MachineActorLogicBox(makeNode(id: i, threshold: threshold, refractory: refractory)))
        ))
    }

    return createMachine(MachineConfig<RouterContext>(
        id: "mesh",
        initial: "run",
        context: RouterContext(),
        states: [
            "run": StateNodeConfig(on: on, invoke: invokes),
        ]
    ))
}
