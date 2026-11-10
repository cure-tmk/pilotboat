import AppKit
import Core
import Observation
import SwiftUI

extension Bundle {
    /// SwiftPM's `Bundle.module` looks for the resource bundle next to `Pilotboat.app`, not inside `Contents/Resources`.
    static let resources: Bundle = Bundle.main.resourceURL
        .flatMap { Bundle(url: $0.appendingPathComponent("Pilotboat_Pilotboat.bundle")) } ?? .module
}

@MainActor @Observable
final class AppState {
    var model: AppModel?
    var bootError: String?
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let state = AppState()
    private var statusItem: StatusItemController?
    private var mainWindow: WindowController?
    private var setupWindow: WindowController?

    func applicationWillFinishLaunching(_ notification: Notification) {
        Notifier.shared.activate()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let statusItem = StatusItemController(state: state)
        self.statusItem = statusItem
        #if DEBUG
        if ProcessInfo.processInfo.environment["PILOTBOAT_OPEN_POPOVER"] == "1" {
            Task { try? await Task.sleep(for: .seconds(1)); statusItem.showPopover() }
        }
        #endif
        Task {
            do {
                let model = try await Bootstrap.make()
                Notifier.shared.model = model
                state.model = model
                didBoot(model)
            } catch {
                state.bootError = AppModel.describe(error)
                appLogger.error("Startup failed: \(self.state.bootError ?? "", privacy: .public)")
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard let model = state.model else { return true }
        (model.onboardingCompleted ? mainWindow : setupWindow)?.show()
        return true
    }

    private func didBoot(_ model: AppModel) {
        let mainWindow = WindowController.main(model: model)
        self.mainWindow = mainWindow
        setupWindow = WindowController.setup(model: model)
        model.showMain = { mainWindow.show() }
        model.closePopover = { [weak statusItem] in statusItem?.closePopover() }
        #if DEBUG
        if ProcessInfo.processInfo.environment["PILOTBOAT_OPEN_MAIN"] == "1" { mainWindow.show() }
        #endif
        guard !model.onboardingCompleted else { return }
        setupWindow?.show()
        awaitOnboarding(model)
    }

    private func awaitOnboarding(_ model: AppModel) {
        let done = withObservationTracking { model.onboardingCompleted } onChange: { [weak self] in
            Task { @MainActor in self?.awaitOnboarding(model) }
        }
        guard done else { return }
        setupWindow?.close()
        model.openMain(section: .activity)
    }
}

@main
struct PilotboatApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    // The status item, popover and windows are AppKit-managed: MenuBarExtra could leave the item stuck highlighted.
    var body: some Scene {
        // Never inserted: with Settings as the only scene, SwiftUI opens the Settings window at launch.
        MenuBarExtra(isInserted: .constant(false)) { EmptyView() } label: { EmptyView() }
        Settings {
            ModelGate(state: delegate.state) { SettingsWindow() }
        }
    }
}

struct ModelGate<Content: View>: View {
    let state: AppState
    var showsQuit = false
    @ViewBuilder let content: () -> Content

    var body: some View {
        if let model = state.model {
            content().environment(model)
        } else {
            VStack(spacing: 8) {
                Text(state.bootError ?? String(localized: "Starting…", bundle: .resources))
                    .foregroundStyle(state.bootError == nil ? Color.secondary : Color.red)
                if showsQuit {
                    Button(String(localized: "Quit Pilotboat", bundle: .resources)) { NSApp.terminate(nil) }
                }
            }
            .padding(16)
        }
    }
}
