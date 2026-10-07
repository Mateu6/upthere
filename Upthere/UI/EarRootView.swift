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

/// One ear plus half of the notch. The background is a single shape spanning
/// both (no seam at the notch edge); the ear hugs the notch, and anything
/// beyond it is transparent (and only exists while the window shrinks).
struct EarRootView: View {
    let model: NotchViewModel
    let side: NotchSide
    let actions: NotchActions

    var body: some View {
        let width = side == .left ? model.leftWidth : model.rightWidth
        let height = model.geometry.height
        let half = model.geometry.notchWidth / 2
        let earFrame = width > 0 ? width + Theme.shoulderRadius : 0
        let alignment: Alignment = side == .left ? .trailing : .leading

        ZStack(alignment: alignment) {
            BandBackground(model: model, side: side, notchHalf: half, earOpen: width > 0)
                .frame(width: earFrame + half, height: height)
            HStack(spacing: 0) {
                if side == .left {
                    ear(width: width, frame: earFrame, height: height)
                    notchHalf(width: half)
                } else {
                    notchHalf(width: half)
                    ear(width: width, frame: earFrame, height: height)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
        .animation(Theme.spring, value: width)
        .contextMenu {
            Button("Settings…", action: actions.openSettings)
            Button("Check for Updates…", action: actions.checkForUpdates)
            Divider()
            Button("Quit Upthere", action: actions.quit)
        }
    }

    private func ear(width: CGFloat, frame: CGFloat, height: CGFloat) -> some View {
        let shape = EarShape(side: side)
        let alignment: Alignment = side == .left ? .trailing : .leading
        return Group {
            if side == .left {
                LeftEarContent(model: model, content: model.content.left)
            } else {
                RightEarContent(model: model, content: model.content.right)
            }
        }
        .frame(width: width, height: height)
        // The shoulder flare sits outside the ear's content width.
        .frame(width: frame, height: height, alignment: alignment)
        .clipShape(shape)
        .contentShape(shape)
        .onHover { model.hover(side, inside: $0) }
        .onTapGesture { model.tap() }
    }

    /// Hover/click target under the physical notch, so the notch itself
    /// reacts. Drawing is done by the band behind it.
    private func notchHalf(width: CGFloat) -> some View {
        Color.clear
            .frame(width: width)
            .contentShape(Rectangle())
            .onHover { model.hover(.center, inside: $0) }
            .onTapGesture { model.tap() }
    }
}

/// The ear and its half of the notch as one shape.
/// Classic: solid black, so the ears read as part of the notch.
/// Aurora: see `AuroraFill`.
private struct BandBackground: View {
    let model: NotchViewModel
    let side: NotchSide
    let notchHalf: CGFloat
    let earOpen: Bool

    var body: some View {
        let shape = EarShape(side: side, notchExtension: notchHalf)
        switch model.prefs.theme {
        case .classic:
            shape.fill(.black)
        case .aurora where !earOpen:
            // Nothing live: just the notch, invisible against the real one.
            shape.fill(.black)
        case .aurora:
            AuroraFill(
                shape: shape, colors: model.palette(for: side).map { Color(nsColor: $0) }, side: side,
                notchHalf: notchHalf)
        }
    }
}

/// Liquid Glass tinted with the cover's colors. Black at the top (melting
/// into the bezel) and towards the notch (so its sides blend in), clearing
/// outwards and downwards where the colors show. Colors run from the notch
/// outwards.
struct AuroraFill<S: Shape>: View {
    let shape: S
    let colors: [Color]
    let side: NotchSide
    /// Width of the notch part at the inner edge of the band.
    let notchHalf: CGFloat

    var body: some View {
        GeometryReader { proxy in
            let w = max(proxy.size.width, 1)
            // Unit positions measured from the inner (notch center) edge.
            let notchEdge = min(1, notchHalf / w)
            let fadeEnd = min(1, (notchHalf + 28) / w)
            let inner: UnitPoint = side == .left ? .trailing : .leading
            let outer: UnitPoint = side == .left ? .leading : .trailing
            ZStack {
                shape.fill(.clear)
                    .glassEffect(.clear.tint(colors[0].opacity(0.2)), in: shape)
                // The cover's colors, strongest at the bottom and away from the notch.
                shape.fill(
                    LinearGradient(
                        stops: [
                            .init(color: colors[0], location: 0),
                            .init(color: colors[0], location: fadeEnd),
                            .init(color: colors[1], location: (fadeEnd + 1) / 2),
                            .init(color: colors[2], location: 1),
                        ], startPoint: inner, endPoint: outer)
                )
                .opacity(0.75)
                .mask(
                    LinearGradient(
                        stops: [.init(color: .clear, location: 0.1), .init(color: .white, location: 1)],
                        startPoint: .top, endPoint: .bottom))
                // Black towards the notch: solid at its center, gone just past its edge.
                shape.fill(
                    LinearGradient(
                        stops: [
                            .init(color: .black, location: 0),
                            .init(color: .black.opacity(0.75), location: notchEdge * 0.7),
                            .init(color: .black.opacity(0.35), location: notchEdge),
                            .init(color: .black.opacity(0), location: fadeEnd),
                        ], startPoint: inner, endPoint: outer))
                // Black at the top, clear at the bottom.
                shape.fill(
                    LinearGradient(
                        stops: [
                            .init(color: .black, location: 0),
                            .init(color: .black.opacity(0.85), location: 0.38),
                            .init(color: .black.opacity(0.05), location: 1),
                        ], startPoint: .top, endPoint: .bottom))
            }
        }
        .animation(.easeInOut(duration: 0.6), value: colors)
    }
}
