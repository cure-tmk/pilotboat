import Core

extension Rule {
    /// "Review requested · All repositories · Ask first"
    func summary(config: Config) -> String {
        let repositories: String = switch repoScope {
        case .all: String(localized: "All repositories", bundle: .resources)
        case .only(let ids) where ids.count == 1:
            config.repository(id: ids[0])?.fullName ?? String(localized: "1 repository", bundle: .resources)
        case .only(let ids): String(localized: "\(ids.count) repositories", bundle: .resources)
        }
        let approval = executionMode == .confirm
            ? String(localized: "Ask first", bundle: .resources)
            : String(localized: "Run automatically", bundle: .resources)
        return [eventKind.shortName, repositories, approval].joined(separator: " · ")
    }
}
