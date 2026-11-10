import SwiftUI

enum MainSection: String, CaseIterable, Identifiable {
    case activity, automations, repositories, health

    var id: Self { self }

    var title: String {
        switch self {
        case .activity: String(localized: "Activity", bundle: .resources)
        case .automations: String(localized: "Automations", bundle: .resources)
        case .repositories: String(localized: "Repositories", bundle: .resources)
        case .health: String(localized: "Health", bundle: .resources)
        }
    }

    var symbol: String {
        switch self {
        case .activity: "list.bullet.rectangle"
        case .automations: "bolt.badge.automatic"
        case .repositories: "folder"
        case .health: "heart.text.square"
        }
    }
}

/// Main window navigation state, shared so the popover and pages can deep-link.
@MainActor @Observable
final class MainRouter {
    var section: MainSection = .activity
    var runId: UUID?
    var automationId: String?
    var repositoryId: UUID?

    /// Selects what is given; the section defaults to the one owning the given selection.
    func show(section: MainSection? = nil, runId: UUID? = nil, automationId: String? = nil, repositoryId: UUID? = nil) {
        if let runId { self.runId = runId }
        if let automationId { self.automationId = automationId }
        if let repositoryId { self.repositoryId = repositoryId }
        if let section {
            self.section = section
        } else if runId != nil {
            self.section = .activity
        } else if automationId != nil {
            self.section = .automations
        } else if repositoryId != nil {
            self.section = .repositories
        }
    }
}

struct MainWindow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var router = model.router
        NavigationSplitView {
            List(MainSection.allCases, selection: Binding($router.section)) { section in
                Label(section.title, systemImage: section.symbol).tag(section)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
            .safeAreaInset(edge: .bottom) {
                StatusLine(status: model.status)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
        } detail: {
            switch router.section {
            case .activity: ActivityPage()
            case .automations: AutomationsPage()
            case .repositories: RepositoriesPage()
            case .health: HealthPage()
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if model.lastErrorMessage != nil {
                ErrorBanner(message: Bindable(model).lastErrorMessage).padding(.horizontal, 16).padding(.top, 8)
            }
        }
        .frame(minWidth: 820, minHeight: 520)
        .navigationTitle(router.section.title)
    }
}
