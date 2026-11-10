import AppKit
import SwiftUI

@MainActor
final class WindowController {
    private let make: () -> NSWindow
    private var window: NSWindow?

    init(make: @escaping () -> NSWindow) { self.make = make }

    func show() {
        let window = self.window ?? make()
        self.window = window
        window.makeKeyAndOrderFront(nil)
        // After ordering front: activating first leaves the new window inactive, so its default button draws grey.
        NSApp.activate()
    }

    func close() { window?.close() }

    static func main(model: AppModel) -> WindowController {
        WindowController {
            let host = NSHostingController(rootView: MainWindow().environment(model))
            host.sizingOptions = [.minSize]
            host.sceneBridgingOptions = .all
            // Style before content: changing the style mask after attaching the host drops the bridged title and toolbar.
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 640),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                  backing: .buffered, defer: false)
            window.titlebarAppearsTransparent = false
            window.contentViewController = host
            window.isReleasedWhenClosed = false
            window.center()
            window.setFrameAutosaveName("main")
            return window
        }
    }

    static func setup(model: AppModel) -> WindowController {
        WindowController {
            let window = NSWindow(contentViewController: NSHostingController(rootView: SetupWindow().frame(width: 560, height: 520).environment(model)))
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.title = String(localized: "Welcome", bundle: .resources)
            window.isReleasedWhenClosed = false
            window.center()
            return window
        }
    }
}
