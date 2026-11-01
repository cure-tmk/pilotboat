import Foundation

public actor FakeCommandRunner: CommandRunner {
    public private(set) var recorded: [Command] = []
    private var queue: [CommandResult]
    private let handler: (@Sendable (Command) -> CommandResult)?

    public init(responses: [CommandResult] = []) {
        queue = responses
        handler = nil
    }

    public init(handler: @escaping @Sendable (Command) -> CommandResult) {
        queue = []
        self.handler = handler
    }

    public func enqueue(_ result: CommandResult) { queue.append(result) }

    public func run(_ command: Command) async throws -> CommandResult {
        recorded.append(command)
        if let handler { return handler(command) }
        return queue.isEmpty ? CommandResult(exitCode: 0, stdout: Data(), stderr: Data()) : queue.removeFirst()
    }
}
