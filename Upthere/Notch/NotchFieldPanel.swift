import AppKit
import SwiftUI

/// A panel that can take keyboard focus without activating Upthere, so
/// typing doesn't pull you out of the app you're in.
private final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// A floating field just under the notch (the timer and reminder fields).
/// Top-anchored as its content grows; closes when it loses focus.
final class NotchFieldPanel: NSObject, NSWindowDelegate {
    private let panel: KeyPanel
    private let geometry: () -> NotchGeometry?
    private var closing = false

    init(geometry: @escaping () -> NotchGeometry?) {
        self.geometry = geometry
        panel = KeyPanel(
            contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered, defer: true)
        super.init()
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 2)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.delegate = self
    }

    var isOpen: Bool { panel.isVisible && !closing }

    func show(_ view: some View) {
        closing = false
        let host = NSHostingController(rootView: view)
        host.sizingOptions = .preferredContentSize
        panel.contentViewController = host
        position()
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        panel.alphaValue = reduceMotion ? 1 : 0
        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
    }

    func close() {
        guard panel.isVisible, !closing else { return }
        closing = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.1
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.closing else { return }
                self.closing = false
                self.panel.orderOut(nil)
                self.panel.contentViewController = nil
            }
        }
    }

    /// Centered under the notch, top-anchored as its height changes.
    private func position() {
        guard let g = geometry() else { return }
        let size = panel.contentViewController?.preferredContentSize ?? NSSize(width: 400, height: 80)
        let origin = NSPoint(
            x: g.notchRect.midX - size.width / 2,
            y: g.screenFrame.maxY - g.height - 10 - size.height)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
    }

    func windowDidResize(_ notification: Notification) {
        // Keep the top edge just under the notch.
        guard let g = geometry() else { return }
        var frame = panel.frame
        let top = g.screenFrame.maxY - g.height - 10
        if abs(frame.maxY - top) > 0.5 {
            frame.origin.y = top - frame.height
            panel.setFrameOrigin(frame.origin)
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        close()
    }
}

/// Small icon buttons in the fields: a soft rounded highlight fades in
/// under the pointer.
struct PanelIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.primary)
            .padding(.horizontal, 5)
            .padding(.vertical, 3)
            .buttonStyle(.plain)
            .modifier(RowHover(pressed: configuration.isPressed))
    }

    private struct RowHover: ViewModifier {
        let pressed: Bool
        @State private var hovering = false

        func body(content: Content) -> some View {
            content
                .background {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(.primary.opacity(pressed ? Theme.Ink.pressedOpacity : hovering ? Theme.Ink.hoverOpacity : 0))
                }
                .scaleEffect(pressed ? 0.94 : 1)
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
                .animation(.spring(duration: 0.2, bounce: 0), value: pressed)
                .animation(.spring(duration: 0.24, bounce: 0), value: hovering)
        }
    }
}
