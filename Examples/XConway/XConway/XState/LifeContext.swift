public nonisolated struct LifeContext: Codable, Sendable, Equatable, Hashable {
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
