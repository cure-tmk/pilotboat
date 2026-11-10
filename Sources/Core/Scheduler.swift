import Foundation

/// Drives `Engine.tick` on the poll interval. Ticks also run while monitoring is off: the engine then skips
/// polling but still resumes timed pauses and handles approvals and the queue.
public actor Scheduler {
    public typealias Sleep = @Sendable (Duration) async throws -> Void

    static let pollRange = 60...900
    static let baseBackoff: TimeInterval = 60
    static let maxBackoff: TimeInterval = 900

    private let engine: Engine
    private let time: any TimeSource
    private let sleep: Sleep
    private var loop: Task<Void, Never>?
    private var sleeper: Task<Void, any Error>?
    private var triggered = false

    public init(engine: Engine, time: any TimeSource = SystemTimeSource(),
                sleep: @escaping Sleep = { try await Task.sleep(for: $0) }) {
        self.engine = engine
        self.time = time
        self.sleep = sleep
    }

    public func start() {
        guard loop == nil else { return }
        loop = Task { await self.run() }
    }

    public func stop() {
        loop?.cancel()
        sleeper?.cancel()
        loop = nil
    }

    public func triggerNow() {
        triggered = true
        sleeper?.cancel()
    }

    private func run() async {
        while !Task.isCancelled {
            triggered = false
            let delay = await delay(after: engine.tick())
            if triggered { continue }
            guard !Task.isCancelled else { break }
            let sleeper = Task { [sleep] in try await sleep(.seconds(delay)) }
            self.sleeper = sleeper
            _ = await sleeper.result
        }
    }

    private func delay(after outcome: TickOutcome) async -> TimeInterval {
        let general = await engine.config.general
        let interval = TimeInterval(min(max(general.pollIntervalSeconds, Self.pollRange.lowerBound), Self.pollRange.upperBound))
        switch outcome {
        case .failed(let failures):
            return min(Self.baseBackoff * pow(2, Double(failures - 1)), Self.maxBackoff)
        case .monitoringOff(let until?):
            return max(0, min(interval, until.timeIntervalSince(time.now)))
        case .completed, .monitoringOff(nil), .busy:
            return interval
        }
    }
}
