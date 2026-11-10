import AppKit
import SwiftUI

@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {
    struct IconState: Equatable {
        var symbol: String
        var badge: Bool
        var count: Int
    }

    private let state: AppState
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private var icon: IconState?

    init(state: AppState) {
        self.state = state
        super.init()
        let host = NSHostingController(rootView: ModelGate(state: state, showsQuit: true) { PopoverView() })
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        // A stable autosave name keeps the user's "visible in menu bar" choice tied to this item, not to a per-launch default.
        item.autosaveName = "pilotboat"
        item.isVisible = true
        if let button = item.button {
            button.target = self
            button.action = #selector(toggle)
            button.sendAction(on: [.leftMouseDown, .rightMouseDown])
            button.imagePosition = .imageLeading
        }
        observe()
    }

    @objc private func toggle() {
        if popover.isShown { closePopover() } else { showPopover() }
    }

    func showPopover() {
        guard let button = item.button, !popover.isShown else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        button.highlight(true)
    }

    func closePopover() {
        popover.performClose(nil)
    }

    func popoverDidClose(_ notification: Notification) {
        item.button?.highlight(false)
    }

    private func observe() {
        let next = withObservationTracking { iconState } onChange: { [weak self] in
            Task { @MainActor in self?.observe() }
        }
        guard next != icon, let button = item.button else { return }
        icon = next
        button.image = Self.image(symbol: next.symbol, badge: next.badge)
        button.title = next.count > 0 ? " \(next.count.formatted())" : ""
    }

    private var iconState: IconState {
        guard let model = state.model else {
            return IconState(symbol: state.bootError == nil ? "sailboat" : "exclamationmark.triangle.fill", badge: false, count: 0)
        }
        let count = model.pendingRuns.count
        return IconState(symbol: model.status.monitoring == .on ? "sailboat.fill" : "sailboat",
                         badge: model.status.lastError != nil || count > 0, count: count)
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
