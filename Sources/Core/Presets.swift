import Foundation

public enum Presets {
    public static let reviewRequestedId = "preset.review-requested"
    public static let reviewReceivedId = "preset.review-received"
    public static let currentVersion = 1

    /// Shipped template bodies by version, used to tell untouched presets from edited ones.
    static let bodies: [String: [Int: String]] = [
        reviewRequestedId: [1: """
            Review the pull request {{pr.url}}.
            Use the gh CLI to read the description, the diff, and existing review comments.
            Do not post comments, approve, or push anything. Summarize your findings for me, ordered by severity.
            """],
        reviewReceivedId: [1: """
            New reviews were submitted on my pull request {{pr.url}}.
            Use the gh CLI to read the unresolved review threads, decide how to address each one, and propose changes.
            Ask me before committing, pushing, or replying to any review comment.
            """],
    ]

    public static func install(into config: inout Config, launcherId: LauncherID = "orca") {
        let presets: [(PromptTemplate, Rule)] = [
            (PromptTemplate(id: reviewRequestedId, name: "Review requested", body: bodies[reviewRequestedId]![currentVersion]!),
             Rule(id: reviewRequestedId, name: "Review requested", priority: 0, eventKind: .reviewRequested,
                  conditions: [.includeDraft(false)], settleSeconds: 0, launcherId: launcherId,
                  workspacePolicy: .alwaysNew, promptTemplateId: reviewRequestedId)),
            (PromptTemplate(id: reviewReceivedId, name: "Review received", body: bodies[reviewReceivedId]![currentVersion]!),
             Rule(id: reviewReceivedId, name: "Review received", priority: 0, eventKind: .reviewSubmitted,
                  conditions: [.actorKind(.human)], settleSeconds: 120, launcherId: launcherId,
                  workspacePolicy: .reuseOrCreate, promptTemplateId: reviewReceivedId)),
        ]
        for (template, rule) in presets {
            if config.promptTemplate(id: template.id) == nil { config.promptTemplates.append(template) }
            if config.rule(id: rule.id) == nil { config.rules.append(rule) }
            if config.presetState[template.id] == nil { config.presetState[template.id] = PresetState(version: currentVersion) }
        }
    }

    /// Rewrites preset templates the user has not edited to the current shipped body. Edited ones are flagged
    /// and listed by `outdatedEditedPresets` so the UI can ask before replacing them.
    public static func upgrade(_ config: inout Config) {
        upgrade(&config, bodies: bodies, to: currentVersion)
    }

    static func upgrade(_ config: inout Config, bodies: [String: [Int: String]], to currentVersion: Int) {
        for (id, versions) in bodies {
            guard var state = config.presetState[id], state.version < currentVersion,
                  let index = config.promptTemplates.firstIndex(where: { $0.id == id }) else { continue }
            if state.editedByUser || config.promptTemplates[index].body != versions[state.version] {
                state.editedByUser = true
            } else {
                config.promptTemplates[index].body = versions[currentVersion]!
                state.version = currentVersion
            }
            config.presetState[id] = state
        }
    }

    public static func outdatedEditedPresets(in config: Config) -> [String] {
        config.presetState.filter { $0.value.editedByUser && $0.value.version < currentVersion }.map(\.key).sorted()
    }

    /// Replaces an edited preset with the current shipped body after the user confirms.
    public static func acceptUpgrade(id: String, in config: inout Config) {
        guard let body = bodies[id]?[currentVersion],
              let index = config.promptTemplates.firstIndex(where: { $0.id == id }) else { return }
        config.promptTemplates[index].body = body
        config.presetState[id] = PresetState(version: currentVersion)
    }
}
