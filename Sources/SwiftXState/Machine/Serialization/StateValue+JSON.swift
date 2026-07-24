extension StateValue {
    public func toJSONValue() -> JSONValue {
        switch self {
        case let .atomic(value):
            return .string(value)
        case let .compound(values):
            var object: [String: JSONValue] = [:]
            for (key, value) in values.sorted(by: { $0.key < $1.key }) {
                object[key] = value.toJSONValue()
            }
            return .object(object)
        }
    }
}
