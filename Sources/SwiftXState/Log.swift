import Foundation

/// Output from a `log` action.
public struct LogOutput: Sendable, Equatable {
    public let label: String?
    public let message: String

    public init(label: String?, message: String) {
        self.label = label
        self.message = message
    }
}

/// Receives messages from `log` actions. Defaults to `print`; override in tests or apps.
public enum LogHandler: Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var sink: (@Sendable (LogOutput) -> Void)?

    public static func setSink(_ handler: (@Sendable (LogOutput) -> Void)?) {
        lock.lock()
        sink = handler
        lock.unlock()
    }

    static func emit(label: String?, value: Any) {
        let output = LogOutput(label: label, message: String(describing: value))
        lock.lock()
        let handler = sink
        lock.unlock()

        if let handler {
            handler(output)
        } else if let label {
            print(label, output.message)
        } else {
            print(output.message)
        }
    }
}

/// Configuration for a `log` action.
public struct LogAction<Context: Sendable>: Sendable {
    public enum Value: Sendable {
        case fixed(String)
        case expression(@Sendable (ActionArgs<Context>) -> SendableValue)
        case contextAndEvent
    }

    public let value: Value
    public let label: String?

    public init(value: Value, label: String? = nil) {
        self.value = value
        self.label = label
    }
}

func resolveLogValue<Context: Sendable>(
    _ action: LogAction<Context>,
    args: ActionArgs<Context>
) -> Any {
    switch action.value {
    case let .fixed(message):
        return message
    case let .expression(expression):
        return expression(args).boxedForInspection
    case .contextAndEvent:
        return "(context: \(String(describing: args.context)), event: \(args.event.type))"
    }
}

/// Logs the current context and triggering event.
public func log<Context: Sendable>(label: String? = nil) -> ActionRef<Context> {
    .log(LogAction(value: .contextAndEvent, label: label))
}

/// Logs a fixed message.
public func log<Context: Sendable>(_ message: String, label: String? = nil) -> ActionRef<Context> {
    .log(LogAction(value: .fixed(message), label: label))
}

/// Logs a runtime value.
public func log<Context: Sendable>(
    _ expression: @escaping @Sendable (ActionArgs<Context>) -> SendableValue,
    label: String? = nil
) -> ActionRef<Context> {
    .log(LogAction(value: .expression(expression), label: label))
}

/// Logs a runtime string.
public func log<Context: Sendable>(
    _ expression: @escaping @Sendable (ActionArgs<Context>) -> String,
    label: String? = nil
) -> ActionRef<Context> {
    log({ args in SendableValue(expression(args)) }, label: label)
}