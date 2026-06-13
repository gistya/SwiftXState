import Foundation
import SwiftXState

// MARK: - Rules (editable via JSON text area, "sent to the nodes")

public nonisolated struct LifeRules: Codable, Sendable, Equatable, Hashable {
    public var birth: [Int]
    public var survive: [Int]

    public init(birth: [Int], survive: [Int]) {
        self.birth = birth.sorted()
        self.survive = survive.sorted()
    }

    public static let conway = LifeRules(birth: [3], survive: [2, 3])
    public static let highLife = LifeRules(birth: [3, 6], survive: [2, 3])
    public static let seeds = LifeRules(birth: [2], survive: [])
    public static let lifeWithoutDeath = LifeRules(birth: [3], survive: [0,1,2,3,4,5,6,7,8])
    public static let dayAndNight = LifeRules(birth: [3,6,7,8], survive: [3,4,6,7,8])

    public var jsonString: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(self),
              let str = String(data: data, encoding: .utf8) else {
            return "{\"birth\":[3],\"survive\":[2,3]}"
        }
        return str
    }

    public static func from(json: String) -> LifeRules? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(LifeRules.self, from: data)
    }
}

// MARK: - Context (holds the grid + rules + playback state). Codable for SwiftData persistence via SwiftXStateSwiftData.

public nonisolated struct LifeContext: Codable, Sendable, Equatable {
    public let width: Int
    public let height: Int
    public var cells: [Bool]          // row-major: index = y * width + x
    public var generation: Int
    public var isPlaying: Bool
    public var rules: LifeRules
    public var speed: Double          // steps per second (UI driven)

    public init(width: Int, height: Int, cells: [Bool]? = nil, generation: Int = 0, isPlaying: Bool = false, rules: LifeRules = .conway, speed: Double = 12.0) {
        self.width = max(8, width)
        self.height = max(8, height)
        let count = self.width * self.height
        if let cells, cells.count == count {
            self.cells = cells
        } else {
            self.cells = Array(repeating: false, count: count)
        }
        self.generation = generation
        self.isPlaying = isPlaying
        self.rules = rules
        self.speed = speed
    }

    public static func empty(w: Int = 128, h: Int = 96) -> LifeContext {
        LifeContext(width: w, height: h)
    }

    public mutating func reset(to newCells: [Bool]? = nil) {
        let count = width * height
        cells = newCells?.count == count ? newCells! : Array(repeating: false, count: count)
        generation = 0
    }

    public subscript(x: Int, y: Int) -> Bool {
        get {
            guard x >= 0, x < width, y >= 0, y < height else { return false }
            return cells[y * width + x]
        }
        set {
            guard x >= 0, x < width, y >= 0, y < height else { return }
            cells[y * width + x] = newValue
        }
    }

    public var liveCount: Int { cells.filter { $0 }.count }
}

// Lightweight snapshot for replay history (avoids copying rules/speed/etc on every generation).
// This is critical for keeping autoplay (Play mode) as fast as manual Step spam.
public struct GridSnapshot: Sendable, Equatable {
    public let generation: Int
    public let cells: [Bool]
}

// MARK: - Events (drive the machine; rules can be sent as JSON to affect guard-like decisions in step assign)

public nonisolated enum LifeEvent: Eventable, Equatable {
    case toggleCell(x: Int, y: Int)
    case step
    case play
    case pause
    case clear
    case randomize(density: Double)
    case loadTemplate(name: String, atX: Int?, atY: Int?)
    case setRulesJSON(String)   // the text area sends rules/guards config here -> "sent out to the nodes"
    case setSpeed(Double)
    case restore(LifeContext)   // used by replay bar to jump the live state to a prior snapshot

    public var type: String {
        switch self {
        case .toggleCell: return "TOGGLE_CELL"
        case .step: return "STEP"
        case .play: return "PLAY"
        case .pause: return "PAUSE"
        case .clear: return "CLEAR"
        case .randomize: return "RANDOMIZE"
        case .loadTemplate: return "LOAD_TEMPLATE"
        case .setRulesJSON: return "SET_RULES_JSON"
        case .setSpeed: return "SET_SPEED"
        case .restore: return "RESTORE"
        }
    }

    public static func == (lhs: LifeEvent, rhs: LifeEvent) -> Bool {
        switch (lhs, rhs) {
        case (.toggleCell(let x1, let y1), .toggleCell(let x2, let y2)):
            return x1 == x2 && y1 == y2
        case (.step, .step), (.play, .play), (.pause, .pause), (.clear, .clear):
            return true
        case (.randomize(let d1), .randomize(let d2)):
            return d1 == d2
        case (.loadTemplate(let n1, let x1, let y1), .loadTemplate(let n2, let x2, let y2)):
            return n1 == n2 && x1 == x2 && y1 == y2
        case (.setRulesJSON(let j1), .setRulesJSON(let j2)):
            return j1 == j2
        case (.setSpeed(let s1), .setSpeed(let s2)):
            return s1 == s2
        case (.restore(let c1), .restore(let c2)):
            return c1 == c2
        default:
            return false
        }
    }
}

// MARK: - Next generation computation (core of "rules" interpreted from context.rules, used inside assign)

public nonisolated func nextGeneration(cells: [Bool], width: Int, height: Int, rules: LifeRules) -> [Bool] {
    var next = Array(repeating: false, count: width * height)
    let dirs = [(-1,-1), (0,-1), (1,-1), (-1,0), (1,0), (-1,1), (0,1), (1,1)]

    for y in 0..<height {
        for x in 0..<width {
            let idx = y * width + x
            let alive = cells[idx]
            var neighbors = 0
            for (dx, dy) in dirs {
                let nx = (x + dx + width) % width   // toroidal wrap (classic for GoL demos)
                let ny = (y + dy + height) % height
                if cells[ny * width + nx] { neighbors += 1 }
            }
            if alive {
                next[idx] = rules.survive.contains(neighbors)
            } else {
                next[idx] = rules.birth.contains(neighbors)
            }
        }
    }
    return next
}
