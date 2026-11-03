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

    func applicationWillFinishLaunching(_ notification: Notification) {
        Notifier.shared.activate()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task {
            do {
                let model = try await Bootstrap.make()
                Notifier.shared.model = model
                state.model = model
            } catch {
                state.bootError = AppModel.describe(error)
                appLogger.error("Startup failed: \(self.state.bootError ?? "", privacy: .public)")
            }
        }
    }
}

@main
struct PilotboatApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            ModelGate(state: delegate.state, showsQuit: true) { PopoverView() }
        } label: {
            StatusIcon(state: delegate.state)
        }
        .menuBarExtraStyle(.window)

        Window(Text("Pilotboat", bundle: .resources), id: WindowID.main) {
            ModelGate(state: delegate.state) { MainWindow() }
        }
        .defaultSize(width: 980, height: 640)
        .windowResizability(.contentMinSize)

        Settings {
            ModelGate(state: delegate.state) { SettingsWindow() }
        }

        Window(Text("Welcome", bundle: .resources), id: WindowID.setup) {
            ModelGate(state: delegate.state) { SetupScene() }
        }
        .defaultSize(width: 560, height: 520)
        .windowResizability(.contentSize)

        #if DEBUG
        // Opened only with PILOTBOAT_PREVIEW_POPOVER=1: a MenuBarExtra panel cannot be captured as a window.
        Window(Text(verbatim: "Popover preview"), id: WindowID.popoverPreview) {
            ModelGate(state: delegate.state) { PopoverView().frame(width: 360) }
        }
        .windowResizability(.contentSize)
        #endif
    }
}

enum WindowID {
    static let main = "main"
    static let setup = "setup"
    #if DEBUG
    static let popoverPreview = "popoverPreview"
    static let previewsPopover = ProcessInfo.processInfo.environment["PILOTBOAT_PREVIEW_POPOVER"] == "1"
    #endif
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

private struct SetupScene: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        SetupWindow()
            .frame(width: 560, height: 520)
            .onChange(of: model.onboardingCompleted) { _, done in if done { dismiss() } }
    }
}

struct StatusIcon: View {
    let state: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack(spacing: 2) {
            Image(nsImage: Self.image(symbol: symbol, badge: showsBadge))
            if let count = state.model?.pendingRuns.count, count > 0 { Text(count, format: .number) }
        }
        .task(id: state.model == nil) {
            guard let model = state.model else { return }
            model.openWindowAction = openWindow
            #if DEBUG
            if WindowID.previewsPopover { openWindow(id: WindowID.popoverPreview) }
            #endif
            guard !model.onboardingCompleted else { return }
            openWindow(id: WindowID.setup)
            // After opening: activating first leaves the new window inactive, so its default button draws grey.
            NSApp.activate()
        }
    }

    private var symbol: String {
        guard let model = state.model else { return state.bootError == nil ? "sailboat" : "exclamationmark.triangle.fill" }
        return model.status.monitoring == .on ? "sailboat.fill" : "sailboat"
    }

    private var showsBadge: Bool {
        guard let model = state.model else { return false }
        return model.status.lastError != nil || !model.pendingRuns.isEmpty
    }

    // A template image can't carry the red dot, so the badged icon is drawn by hand.
    private static func image(symbol: String, badge: Bool) -> NSImage {
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        guard let base = NSImage(systemSymbolName: symbol, accessibilityDescription: "Pilotboat")?.withSymbolConfiguration(config) else { return NSImage() }
        guard badge else {
            base.isTemplate = true
            return base
        }
        let image = NSImage(size: base.size, flipped: false) { rect in
            base.draw(in: rect)
            NSColor.labelColor.set()
            rect.fill(using: .sourceAtop)
            let dot = NSRect(x: rect.maxX - 6, y: rect.maxY - 6, width: 6, height: 6)
            NSColor.systemRed.setFill()
            NSBezierPath(ovalIn: dot).fill()
            return true
        }
        image.isTemplate = false
        return image
    }
}
