import AppKit
import SwiftUI

/// A panel that takes clicks and keystrokes without activating AgentSessionBar, so Cursor stays the active app.
final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// The inbox pinned on screen as a floating panel, for answering while working in another window.
@MainActor
final class PanelController {
    static let shared = PanelController()
    private var panel: FloatingPanel?

    func toggle() {
        if let panel, panel.isVisible { panel.orderOut(nil) } else { show() }
    }

    func show() {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        panel.orderFrontRegardless()
        panel.makeKey()
    }

    private func makePanel() -> FloatingPanel {
        let panel = FloatingPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 560),
                                  styleMask: [.nonactivatingPanel, .titled, .closable, .resizable, .utilityWindow],
                                  backing: .buffered, defer: false)
        panel.title = "AgentSessionBar"
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: InboxView(store: DeckStore.shared, inPanel: true))
        panel.setFrameAutosaveName("agentsessionbar.panel")
        if !panel.setFrameUsingName("agentsessionbar.panel") { panel.center() }
        return panel
    }
}

func frontmostBundleID() -> String {
    NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "-"
}
