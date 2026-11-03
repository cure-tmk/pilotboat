import Core
import SwiftUI

extension RunState {
    var label: String {
        switch self {
        case .settling: String(localized: "Collecting reviews…", bundle: .resources)
        case .pendingApproval: String(localized: "Waiting for you", bundle: .resources)
        case .queued, .launching: String(localized: "Starting…", bundle: .resources)
        case .launched: String(localized: "Started", bundle: .resources)
        case .held: String(localized: "Held until tomorrow", bundle: .resources)
        case .failed: String(localized: "Failed", bundle: .resources)
        case .skipped: String(localized: "Skipped", bundle: .resources)
        }
    }

    var symbol: String {
        switch self {
        case .settling: "clock"
        case .pendingApproval: "hand.raised.fill"
        case .queued, .launching: "arrow.triangle.2.circlepath"
        case .launched: "checkmark.circle.fill"
        case .held: "pause.circle"
        case .failed: "xmark.octagon.fill"
        case .skipped: "minus.circle"
        }
    }

    var color: Color {
        switch self {
        case .settling, .held, .skipped: .secondary
        case .pendingApproval: .orange
        case .queued, .launching: .blue
        case .launched: .green
        case .failed: .red
        }
    }
}

extension SkipReason {
    var label: String {
        switch self {
        case .userSkipped: String(localized: "you skipped it", bundle: .resources)
        case .approvalTimeout: String(localized: "no answer in 24 hours", bundle: .resources)
        case .prClosed: String(localized: "pull request was closed", bundle: .resources)
        case .monitoringOff: String(localized: "monitoring was off", bundle: .resources)
        case .ruleRemoved: String(localized: "automation was removed", bundle: .resources)
        case .crossRepository: String(localized: "pull request is from a fork", bundle: .resources)
        }
    }
}

extension Run {
    var stateLabel: String {
        guard state == .skipped, let skipReason else { return state.label }
        return String(localized: "Skipped · \(skipReason.label)", bundle: .resources)
    }

    var pullRequest: PullRequestRef? { snapshot?.subject.pullRequest }

    /// "name #number", without the owner.
    var shortTitle: String {
        "\(repo.split(separator: "/").last.map(String.init) ?? repo) #\(prNumber)"
    }
}
