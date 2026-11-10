import Core
import Foundation

struct ToolCheck: Hashable, Sendable {
    var name: String
    var path: String?
    var version: String?

    var isOK: Bool { path != nil && version != nil }

    var item: DiagnosticItem {
        guard let path else {
            return DiagnosticItem(level: .error, title: name, detail: String(localized: "Not found. Install it, then check again", bundle: .resources))
        }
        return DiagnosticItem(level: version == nil ? .warning : .ok, title: name,
                              detail: "\(path) — \(version ?? String(localized: "version unknown", bundle: .resources))")
    }
}

struct HealthReport {
    var tools: [ToolCheck] = []
    var groups: [(owner: String, items: [DiagnosticItem])] = []
    var searchPath: [String] = []

    func tool(_ name: String) -> ToolCheck? { tools.first { $0.name == name } }

    /// Groups engine diagnostics by their `"<launcher id>: "` title prefix, which is dropped from each item.
    /// Items without the prefix (event sources) form a group named after their own title.
    static func make(from items: [DiagnosticItem], tools: [ToolCheck] = [], searchPath: [String] = []) -> HealthReport {
        var groups: [(owner: String, items: [DiagnosticItem])] = []
        for var item in items {
            let owner: String
            if let range = item.title.range(of: ": ") {
                owner = String(item.title[..<range.lowerBound])
                item.title = String(item.title[range.upperBound...])
            } else {
                owner = item.title
            }
            if let index = groups.firstIndex(where: { $0.owner == owner }) {
                groups[index].items.append(item)
            } else {
                groups.append((owner, [item]))
            }
        }
        return HealthReport(tools: tools, groups: groups, searchPath: searchPath)
    }
}
