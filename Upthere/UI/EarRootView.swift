import SwiftUI

enum Theme {
    static let spring = Animation.spring(response: 0.36, dampingFraction: 0.84)
    static let claude = NSColor(srgbRed: 0.85, green: 0.47, blue: 0.34, alpha: 1)
    static let amber = NSColor(srgbRed: 1.0, green: 0.74, blue: 0.24, alpha: 1)
    static let secondary = Color.white.opacity(0.58)
    static let earRadius: CGFloat = 10
    /// Bottom corner radius used to hide the black filler inside the physical notch.
    static let notchCornerRadius: CGFloat = 12

    static func time(_ seconds: TimeInterval) -> String {
        let s = Int(max(0, seconds.rounded(.down)))
        return s >= 3600
            ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
            : String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// One ear plus half of the notch. The ear hugs the notch; anything beyond
/// it is transparent (and only exists while the window shrinks).
struct EarRootView: View {
    let model: NotchViewModel
    let side: NotchSide
    let actions: NotchActions

    var body: some View {
        let width = side == .left ? model.leftWidth : model.rightWidth
        let height = model.geometry.height
        let earOpen = width > 0

        HStack(spacing: 0) {
            if side == .left {
                Spacer(minLength: 0)
                ear(width: width, height: height)
                notchHalf(earOpen: earOpen)
            } else {
                notchHalf(earOpen: earOpen)
                ear(width: width, height: height)
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(Theme.spring, value: width)
        .contextMenu {
            Button("Settings…", action: actions.openSettings)
            Button("Check for Updates…", action: actions.checkForUpdates)
            Divider()
            Button("Quit Upthere", action: actions.quit)
        }
    }

    private func ear(width: CGFloat, height: CGFloat) -> some View {
        let shape = UnevenRoundedRectangle(
            bottomLeadingRadius: side == .left ? min(Theme.earRadius, width / 2) : 0,
            bottomTrailingRadius: side == .right ? min(Theme.earRadius, width / 2) : 0
        )
        return ZStack {
            shape.fill(.black)
            Group {
                if side == .left {
                    LeftEarContent(model: model, content: model.content.left)
                } else {
                    RightEarContent(model: model, content: model.content.right)
                }
            }
            .frame(width: width, height: height)
        }
        .frame(width: width, height: height)
        .clipShape(shape)
        .contentShape(shape)
        .onHover { model.hover(side, inside: $0) }
        .onTapGesture { model.tap() }
    }

    /// Black filler under the physical notch so hovering the notch itself
    /// works. Its outer corner rounds off when the ear is closed, staying
    /// inside the notch's own curve.
    private func notchHalf(earOpen: Bool) -> some View {
        let radius = earOpen ? 0 : Theme.notchCornerRadius
        return UnevenRoundedRectangle(
            bottomLeadingRadius: side == .left ? radius : 0,
            bottomTrailingRadius: side == .right ? radius : 0
        )
        .fill(.black)
        .frame(width: model.geometry.notchWidth / 2)
        .contentShape(Rectangle())
        .onHover { model.hover(.center, inside: $0) }
        .onTapGesture { model.tap() }
    }
}
