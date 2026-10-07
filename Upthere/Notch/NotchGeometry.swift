import AppKit

/// Where the (physical or virtual) notch sits on a screen, in screen coordinates.
struct NotchGeometry: Equatable {
    var screenFrame: CGRect
    var notchRect: CGRect
    var hasNotch: Bool

    var height: CGFloat { notchRect.height }
    var notchWidth: CGFloat { notchRect.width }
    /// Room available on each side of the notch.
    var leftRoom: CGFloat { notchRect.minX - screenFrame.minX }
    var rightRoom: CGFloat { screenFrame.maxX - notchRect.maxX }

    static func make(for screen: NSScreen) -> NotchGeometry {
        let frame = screen.frame
        let top = screen.safeAreaInsets.top
        if top > 0, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            // The auxiliary areas are the menu bar regions beside the notch.
            let minX = frame.minX + left.width
            let maxX = frame.maxX - right.width
            return NotchGeometry(
                screenFrame: frame,
                notchRect: CGRect(x: minX, y: frame.maxY - top, width: maxX - minX, height: top),
                hasNotch: true
            )
        }
        // No notch: a zero-width "virtual notch" at the top center, as tall
        // as the menu bar. The ears meet in the middle and form a pill.
        let menuBar = max(24, frame.maxY - screen.visibleFrame.maxY)
        return NotchGeometry(
            screenFrame: frame,
            notchRect: CGRect(x: frame.midX, y: frame.maxY - menuBar, width: 0, height: min(menuBar, 32)),
            hasNotch: false
        )
    }
}

enum ScreenPicker {
    static func screen(for choice: DisplayChoice) -> NSScreen? {
        switch choice {
        case .builtIn:
            NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main ?? NSScreen.screens.first
        case .main:
            NSScreen.main ?? NSScreen.screens.first
        }
    }
}
