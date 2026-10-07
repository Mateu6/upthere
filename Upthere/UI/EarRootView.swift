import SwiftUI

enum Theme {
    static let spring = Animation.spring(response: 0.36, dampingFraction: 0.84)
    /// The ear open/close spring (perceptual duration; critically damped, no
    /// overshoot), run by EarWindow on the mask.
    static let earDuration: Double = 0.34
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

/// One side: its half of the notch plus the ear, laid out in a fixed-size
/// container anchored at the notch. The visible shape (and its open/close
/// animation) is a Core Animation mask owned by `EarWindow`, so this view
/// just fills the container and places content at the target width.
struct EarRootView: View {
    let model: NotchViewModel
    let side: NotchSide
    let actions: NotchActions

    var body: some View {
        let width = side == .left ? model.leftWidth : model.rightWidth
        let height = model.geometry.height
        let half = model.geometry.notchWidth / 2

        ZStack {
            Background(model: model, side: side, notchHalf: half, earOpen: width > 0)
            HStack(spacing: 0) {
                if side == .left {
                    Spacer(minLength: 0)
                    ear(width: width, height: height)
                    notchHalf(width: half)
                } else {
                    notchHalf(width: half)
                    ear(width: width, height: height)
                    Spacer(minLength: 0)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contextMenu {
            Button("Settings…", action: actions.openSettings)
            Button("Check for Updates…", action: actions.checkForUpdates)
            Divider()
            Button("Quit Upthere", action: actions.quit)
        }
    }

    private func ear(width: CGFloat, height: CGFloat) -> some View {
        Group {
            if side == .left {
                LeftEarContent(model: model, content: model.content.left)
            } else {
                RightEarContent(model: model, content: model.content.right)
            }
        }
        .frame(width: width, height: height)
        .contentShape(Rectangle())
        .onHover { model.hover(side, inside: $0) }
        .onTapGesture { model.tap(side) }
    }

    /// Under the physical notch. It opens nothing, but moving across it
    /// counts as leaving an ear.
    private func notchHalf(width: CGFloat) -> some View {
        Color.clear
            .frame(width: width)
            .contentShape(Rectangle())
            .onHover { model.hover(.center, inside: $0) }
    }
}

/// Fills the whole container; the mask decides what shows.
/// Classic: solid black, so the ears read as part of the notch.
/// Aurora: see `AuroraFill`. Clear: see `ClearGlassFill`.
private struct Background: View {
    let model: NotchViewModel
    let side: NotchSide
    let notchHalf: CGFloat
    let earOpen: Bool

    var body: some View {
        switch model.prefs.theme {
        case .aurora where earOpen:
            AuroraFill(colors: model.palette(for: side).map { Color(nsColor: $0) }, side: side, notchHalf: notchHalf)
        case .clear where earOpen:
            ClearGlassFill(
                style: model.prefs.clearGlassStyle, blackFade: model.prefs.clearBlackFade,
                colors: model.palette(for: side).map { Color(nsColor: $0) }, side: side)
        default:
            Color.black
        }
    }
}

/// Liquid Glass tinted with the cover's colors. Black at the top (melting
/// into the bezel) and towards the notch (so its sides blend in), clearing
/// outwards and downwards where the colors show. Stops are in points from
/// the notch, so the gradient stays put while the ear opens and closes.
struct AuroraFill: View {
    let colors: [Color]
    let side: NotchSide
    let notchHalf: CGFloat

    var body: some View {
        GeometryReader { proxy in
            let w = max(proxy.size.width, 1)
            let at = { (points: CGFloat) in min(1, points / w) }
            let notchEdge = at(notchHalf)
            let fadeEnd = at(notchHalf + 28)
            let inner: UnitPoint = side == .left ? .trailing : .leading
            let outer: UnitPoint = side == .left ? .leading : .trailing
            ZStack {
                Rectangle().fill(.clear)
                    .glassEffect(.clear.tint(colors[0].opacity(0.2)), in: Rectangle())
                // The cover's colors, strongest at the bottom and away from the notch.
                Rectangle()
                    .fill(
                        LinearGradient(
                            stops: [
                                .init(color: colors[0], location: 0),
                                .init(color: colors[0], location: fadeEnd),
                                .init(color: colors[1], location: at(notchHalf + 150)),
                                .init(color: colors[2], location: at(notchHalf + 300)),
                            ], startPoint: inner, endPoint: outer)
                    )
                    .opacity(0.75)
                    .mask(
                        LinearGradient(
                            stops: [.init(color: .clear, location: 0.1), .init(color: .white, location: 1)],
                            startPoint: .top, endPoint: .bottom))
                // Black towards the notch: solid at its center, gone just past its edge.
                Rectangle()
                    .fill(
                        LinearGradient(
                            stops: [
                                .init(color: .black, location: 0),
                                .init(color: .black.opacity(0.75), location: notchEdge * 0.7),
                                .init(color: .black.opacity(0.35), location: notchEdge),
                                .init(color: .black.opacity(0), location: fadeEnd),
                            ], startPoint: inner, endPoint: outer))
                // Black at the top, clear at the bottom.
                Rectangle()
                    .fill(
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

/// Native Liquid Glass with a light tint from the cover (much subtler than
/// Aurora), optionally with the black-at-the-top fade. Nothing is painted
/// under the notch: the glass runs behind it, so the physical notch keeps
/// its own rounded shape.
struct ClearGlassFill: View {
    let style: GlassStyle
    let blackFade: Bool
    let colors: [Color]
    let side: NotchSide

    var body: some View {
        let inner: UnitPoint = side == .left ? .trailing : .leading
        let outer: UnitPoint = side == .left ? .leading : .trailing
        ZStack {
            Rectangle().fill(.clear)
                .glassEffect((style == .regular ? Glass.regular : .clear).tint(colors[0].opacity(0.14)), in: Rectangle())
            // A hint of the cover's colors along the bottom.
            Rectangle()
                .fill(LinearGradient(colors: colors, startPoint: inner, endPoint: outer))
                .opacity(0.28)
                .mask(
                    LinearGradient(
                        stops: [.init(color: .clear, location: 0.35), .init(color: .white, location: 1)],
                        startPoint: .top, endPoint: .bottom))
            if blackFade {
                Rectangle().fill(
                    LinearGradient(
                        stops: [
                            .init(color: .black, location: 0),
                            .init(color: .black.opacity(0.75), location: 0.38),
                            .init(color: .black.opacity(0), location: 1),
                        ], startPoint: .top, endPoint: .bottom))
            }
        }
        // White content on glass: keep the glass in its dark appearance.
        .environment(\.colorScheme, .dark)
        .animation(.smooth(duration: 0.3), value: blackFade)
        .animation(.easeInOut(duration: 0.6), value: colors)
    }
}
