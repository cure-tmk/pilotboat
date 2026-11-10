import Core

extension EventKind {
    /// Short label used in summaries, e.g. "Review requested".
    var shortName: String {
        switch self {
        case .reviewRequested: String(localized: "Review requested", bundle: .resources)
        case .reviewSubmitted: String(localized: "Review received", bundle: .resources)
        default: String(localized: "Unsupported trigger", bundle: .resources)
        }
    }

    /// Trigger name as offered in pickers and menus.
    var triggerName: String {
        switch self {
        case .reviewRequested: String(localized: "When someone requests my review", bundle: .resources)
        case .reviewSubmitted: String(localized: "When someone reviews my pull request", bundle: .resources)
        default: String(localized: "Unsupported trigger (\(rawValue))", bundle: .resources)
        }
    }

    var triggerDescription: String {
        switch self {
        case .reviewRequested: String(localized: "Runs when a pull request asks for your review", bundle: .resources)
        case .reviewSubmitted: String(localized: "Runs when reviews arrive on a pull request you opened", bundle: .resources)
        default: String(localized: "This trigger needs a newer version of Pilotboat", bundle: .resources)
        }
    }
}

extension EventKind {
    /// Filters a new automation starts with; the editor keeps Filters collapsed while these are unchanged.
    var defaultConditions: [Condition] { self == .reviewRequested ? [.includeDraft(false)] : [] }
    var defaultSettleSeconds: Int { self == .reviewRequested ? 0 : 120 }
}
