import Foundation
import os

/// Test double that records every command it is asked to run.
public final class FakeCommandRunner: CommandRunner, Sendable {
    private struct State {
        var calls: [Command] = []
        var responses: [CommandResult] = []
        var rules: [(prefix: [String], result: CommandResult)] = []
    }

    private let state: OSAllocatedUnfairLock<State>
    private let handler: (@Sendable (Command) -> CommandResult)?
    private let scripted: Bool

    /// Answers with `responses` in order, then with exit code 0 and no output.
    public init(responses: [CommandResult] = []) {
        state = OSAllocatedUnfairLock(initialState: State(responses: responses))
        handler = nil
        scripted = false
    }

    /// Each command consumes the first rule whose prefix matches `[executable] + arguments`;
    /// an unmatched command exits 99 with "unscripted: <argv>" on stderr.
    public init(rules: [(prefix: [String], result: CommandResult)]) {
        state = OSAllocatedUnfairLock(initialState: State(rules: rules))
        handler = nil
        scripted = true
    }

    public init(handler: @escaping @Sendable (Command) -> CommandResult) {
        state = OSAllocatedUnfairLock(initialState: State())
        self.handler = handler
        scripted = false
    }

    public var calls: [Command] { state.withLock { $0.calls } }

    public func enqueue(_ result: CommandResult) { state.withLock { $0.responses.append(result) } }

    public func run(_ command: Command) async throws -> CommandResult {
        let argv = [command.executable] + command.arguments
        let next: CommandResult? = state.withLock { s in
            s.calls.append(command)
            if handler != nil { return nil }
            if scripted {
                guard let i = s.rules.firstIndex(where: { argv.starts(with: $0.prefix) }) else {
                    return CommandResult(exitCode: 99, stdout: Data(), stderr: Data("unscripted: \(argv)".utf8))
                }
                return s.rules.remove(at: i).result
            }
            return s.responses.isEmpty ? CommandResult(exitCode: 0, stdout: Data(), stderr: Data()) : s.responses.removeFirst()
        }
        return next ?? handler!(command)
    }
}
