import Foundation

public enum PathResolver {
    static let beginMarker = "__PILOTBOAT_BEGIN__"
    static let endMarker = "__PILOTBOAT_END__"

    public static func loginShellPath(shell: String = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh") async -> [String]? {
        let script = "printf \"\(beginMarker)%s\(endMarker)\" \"$PATH\""
        let command = Command(shell, ["-l", "-i", "-c", script], environment: ["TERM": "dumb"], timeout: 5)
        guard let result = try? await ProcessRunner(searchPath: []).run(command), !result.timedOut else { return nil }
        return extractPath(from: result.stdoutText)
    }

    static func extractPath(from output: String) -> [String]? {
        guard let begin = output.range(of: beginMarker),
              let end = output.range(of: endMarker, range: begin.upperBound..<output.endIndex) else { return nil }
        let entries = output[begin.upperBound..<end.lowerBound].split(separator: ":").map(String.init)
        return entries.isEmpty ? nil : entries
    }

    public static func resolve(explicit: [String] = []) async -> [String] {
        let home = NSHomeDirectory()
        let fallbacks = ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin", "/Applications/Orca.app/Contents/Resources/bin", "/usr/bin", "/bin"]
        var seen = Set<String>()
        return (explicit + (await loginShellPath() ?? []) + fallbacks).filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    public static func find(_ name: String, in searchPath: [String]) -> String? {
        let fm = FileManager.default
        if name.contains("/") { return fm.isExecutableFile(atPath: name) ? name : nil }
        return searchPath.map { "\($0)/\(name)" }.first { fm.isExecutableFile(atPath: $0) }
    }
}
