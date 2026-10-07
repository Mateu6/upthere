import SwiftUI

enum Theme {
    static let spring = Animation.spring(response: 0.36, dampingFraction: 0.84)
    static let claude = NSColor(srgbRed: 0.85, green: 0.47, blue: 0.34, alpha: 1)
    static let amber = NSColor(srgbRed: 1.0, green: 0.74, blue: 0.24, alpha: 1)
    static let secondary = Color.white.opacity(0.58)
    static let earRadius: CGFloat = 10
    /// Concave flare where an ear meets the screen's top edge.
    static let shoulderRadius: CGFloat = 6
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
        let shape = EarShape(side: side)
        let alignment: Alignment = side == .left ? .trailing : .leading
        return ZStack(alignment: alignment) {
            EarBackground(model: model, side: side, shape: shape)
            Group {
                if side == .left {
                    LeftEarContent(model: model, content: model.content.left)
                } else {
                    RightEarContent(model: model, content: model.content.right)
                }
            }
            .frame(width: width, height: height)
        }
        // The shoulder flare sits outside the ear's content width.
        .frame(width: width > 0 ? width + Theme.shoulderRadius : 0, height: height, alignment: alignment)
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
        let shape = UnevenRoundedRectangle(
            bottomLeadingRadius: side == .left ? radius : 0,
            bottomTrailingRadius: side == .right ? radius : 0
        )
        // Mostly hidden by the physical notch, but its corners show: in
        // Aurora it carries the same gradient as the ears, so the notch's own
        // rounded shape sits inside one continuous band of color.
        return Group {
            if model.prefs.theme == .aurora && earOpen {
                AuroraFill(shape: shape, colors: model.palette(for: side).map { Color(nsColor: $0) }, side: side, solid: true)
            } else {
                shape.fill(.black)
            }
        }
        .frame(width: model.geometry.notchWidth / 2)
        .contentShape(Rectangle())
        .onHover { model.hover(.center, inside: $0) }
        .onTapGesture { model.tap() }
    }
}

/// Classic: solid black, so the ears read as part of the notch.
/// Aurora: see `AuroraFill`.
private struct EarBackground: View {
    let model: NotchViewModel
    let side: NotchSide
    let shape: EarShape

    var body: some View {
        switch model.prefs.theme {
        case .classic:
            shape.fill(.black)
        case .aurora:
            AuroraFill(shape: shape, colors: model.palette(for: side).map { Color(nsColor: $0) }, side: side)
        }
    }
}

/// Liquid Glass tinted with the cover's colors: black at the top (melting
/// into the notch and bezel), clearing towards the bottom where the colors
/// show. Colors run from the notch outwards; `solid` uses only the innermost
/// color (for the strip under the notch, so it meets both ears seamlessly).
struct AuroraFill<S: Shape>: View {
    let shape: S
    let colors: [Color]
    let side: NotchSide
    var solid = false

    var body: some View {
        let inner: UnitPoint = side == .left ? .trailing : .leading
        let outer: UnitPoint = side == .left ? .leading : .trailing
        ZStack {
            if !solid {
                shape.fill(.clear)
                    .glassEffect(.clear.tint(colors[0].opacity(0.22)), in: shape)
            }
            shape.fill(LinearGradient(colors: solid ? [colors[0], colors[0]] : colors, startPoint: inner, endPoint: outer))
                .opacity(0.75)
                .mask(
                    LinearGradient(
                        stops: [.init(color: .clear, location: 0.1), .init(color: .white, location: 1)],
                        startPoint: .top, endPoint: .bottom))
            shape.fill(
                LinearGradient(
                    stops: [
                        .init(color: .black, location: 0),
                        .init(color: .black.opacity(0.85), location: 0.38),
                        .init(color: .black.opacity(0.05), location: 1),
                    ], startPoint: .top, endPoint: .bottom))
        }
        .animation(.easeInOut(duration: 0.6), value: colors)
    }
}
