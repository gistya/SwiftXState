import Foundation
import SwiftXState

// MARK: - Templates (preloaded patterns you can "drop in")

public enum LifeTemplate: String, CaseIterable, Identifiable {
    case glider = "Glider"
    case blinker = "Blinker"
    case toad = "Toad"
    case beacon = "Beacon"
    case pulsar = "Pulsar"
    case block = "Block"
    case beehive = "Beehive"
    case loaf = "Loaf"
    case boat = "Boat"
    case lwss = "LWSS"
    case gosperGliderGun = "Gosper Glider Gun"

    public var id: String { rawValue }

    /// Relative cells (offsets from top-left anchor). Drop places the anchor near center.
    public var cells: [(Int, Int)] {
        switch self {
        case .glider: return [(1,0),(2,1),(0,2),(1,2),(2,2)]
        case .blinker: return [(0,1),(1,1),(2,1)]
        case .toad: return [(1,0),(2,0),(0,1),(1,1),(2,1),(3,1)]
        case .beacon: return [(0,0),(1,0),(0,1),(3,2),(2,3),(3,3)]
        case .pulsar:
            return [
                (2,0),(3,0),(4,0),(0,2),(5,2),(0,3),(5,3),(0,4),(5,4),(2,5),(3,5),(4,5),
                (2,7),(3,7),(4,7),(0,8),(5,8),(0,9),(5,9),(0,10),(5,10),(2,12),(3,12),(4,12)
            ]
        case .block: return [(0,0),(1,0),(0,1),(1,1)]
        case .beehive: return [(1,0),(2,0),(0,1),(3,1),(1,2),(2,2)]
        case .loaf: return [(1,0),(2,0),(0,1),(3,1),(1,2),(2,3)]
        case .boat: return [(0,0),(1,0),(0,1),(2,1),(1,2)]
        case .lwss: return [(1,0),(2,0),(3,0),(0,1),(3,1),(3,2),(0,2),(1,3),(2,3)]
        case .gosperGliderGun:
            return [
                (0,4),(0,5),(1,4),(1,5),(10,4),(10,5),(10,6),(11,3),(11,7),(12,2),(12,8),
                (13,2),(13,8),(14,5),(15,3),(15,7),(16,4),(16,5),(16,6),(17,5),(20,2),
                (20,3),(20,4),(21,2),(21,4),(21,5),(22,3),(24,1),(24,2),(24,4),(24,5),
                (34,3),(34,4),(35,3),(35,4)
            ]
        }
    }
}

// MARK: - Machine factory (inline assigns for mutation; JSON rules flow through context)

public enum LifeMachineFactory {
    public static let machine: StateMachine<LifeContext> = {
        let config = MachineConfig<LifeContext>(
            id: "life",
            initial: "running",
            context: LifeContext.empty(),
            states: [
                "running": StateNodeConfig(
                    on: [
                        "TOGGLE_CELL": .single(TransitionConfig(
                            actions: [
                                assign { (ctx: inout LifeContext, args: ActionArgs<LifeContext>) in
                                    if let evt = args.event as? LifeEvent, case .toggleCell(let x, let y) = evt {
                                        ctx[x, y].toggle()
                                    }
                                }
                            ]
                        )),
                        "STEP": .single(TransitionConfig(
                            actions: [
                                assign { (ctx: inout LifeContext, _: ActionArgs<LifeContext>) in
                                    ctx.cells = nextGeneration(cells: ctx.cells, width: ctx.width, height: ctx.height, rules: ctx.rules)
                                    ctx.generation += 1
                                }
                            ]
                        )),
                        "CLEAR": .single(TransitionConfig(
                            actions: [
                                assign { (ctx: inout LifeContext, _: ActionArgs<LifeContext>) in
                                    ctx.reset()
                                }
                            ]
                        )),
                        "RANDOMIZE": .single(TransitionConfig(
                            actions: [
                                assign { (ctx: inout LifeContext, args: ActionArgs<LifeContext>) in
                                    var density = 0.28
                                    if let evt = args.event as? LifeEvent, case .randomize(let d) = evt { density = d }
                                    let count = ctx.width * ctx.height
                                    ctx.cells = (0..<count).map { _ in Double.random(in: 0...1) < density }
                                    ctx.generation = 0
                                }
                            ]
                        )),
                        "LOAD_TEMPLATE": .single(TransitionConfig(
                            actions: [
                                assign { (ctx: inout LifeContext, args: ActionArgs<LifeContext>) in
                                    guard let evt = args.event as? LifeEvent,
                                          case .loadTemplate(let name, let atX, let atY) = evt,
                                          let tmpl = LifeTemplate(rawValue: name) else { return }
                                    let offsets = tmpl.cells
                                    let baseX = atX ?? (ctx.width / 2 - 8)
                                    let baseY = atY ?? (ctx.height / 2 - 6)
                                    for (ox, oy) in offsets {
                                        let x = (baseX + ox + ctx.width) % ctx.width
                                        let y = (baseY + oy + ctx.height) % ctx.height
                                        ctx[x, y] = true
                                    }
                                }
                            ]
                        )),
                        "SET_RULES_JSON": .single(TransitionConfig(
                            actions: [
                                assign { (ctx: inout LifeContext, args: ActionArgs<LifeContext>) in
                                    if let evt = args.event as? LifeEvent, case .setRulesJSON(let json) = evt {
                                        if let parsed = LifeRules.from(json: json) {
                                            ctx.rules = parsed
                                        }
                                    }
                                }
                            ]
                        )),
                        "SET_SPEED": .single(TransitionConfig(
                            actions: [
                                assign { (ctx: inout LifeContext, args: ActionArgs<LifeContext>) in
                                    if let evt = args.event as? LifeEvent, case .setSpeed(let s) = evt {
                                        ctx.speed = max(0.5, min(60.0, s))
                                    }
                                }
                            ]
                        )),
                        "PLAY": .single(TransitionConfig(
                            actions: [
                                assign { (ctx: inout LifeContext, _: ActionArgs<LifeContext>) in
                                    ctx.isPlaying = true
                                }
                            ]
                        )),
                        "PAUSE": .single(TransitionConfig(
                            actions: [
                                assign { (ctx: inout LifeContext, _: ActionArgs<LifeContext>) in
                                    ctx.isPlaying = false
                                }
                            ]
                        )),
                        "RESTORE": .single(TransitionConfig(
                            actions: [
                                assign { (ctx: inout LifeContext, args: ActionArgs<LifeContext>) in
                                    if let evt = args.event as? LifeEvent,
                                       case .restore(let saved) = evt {
                                        ctx = saved
                                    }
                                }
                            ]
                        ))
                    ]
                )
            ]
        )
        return createMachine(config)
    }()
}
