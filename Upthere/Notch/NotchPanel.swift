import AppKit
import SwiftUI

/// A borderless, non-activating panel that floats over the menu bar on every
/// space, including full-screen ones. It never becomes key or main, so
/// clicking it never steals focus from the app you're using.
final class NotchPanel: NSPanel {
    init() {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isMovable = false
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        acceptsMouseMovedEvents = true
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Accepts the first click even though the panel is never key.
final class NotchHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
