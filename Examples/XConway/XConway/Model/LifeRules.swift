import Foundation

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
