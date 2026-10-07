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
        let alignment: Alignment = side == .left ? .trailing : .leading

        Group {
            if model.prefs.theme == .clear {
                glassBand(width: width, height: height, half: half, alignment: alignment)
            } else {
                ZStack {
                    Background(model: model, side: side, notchHalf: half, earOpen: width > 0)
                    content(width: width, height: height, half: half)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
        .contextMenu {
            Button("Settings…", action: actions.openSettings)
            Button("Check for Updates…", action: actions.checkForUpdates)
            Divider()
            Button("Quit Upthere", action: actions.quit)
        }
    }

    private func content(width: CGFloat, height: CGFloat, half: CGFloat) -> some View {
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

    /// Glass theme: the glass takes the ear's exact shape, so its native rim
    /// highlight follows the shoulder and corners. The shape's frame springs
    /// (same spring as the layer mask in the other themes) while the content
    /// stays laid out at its target width and is masked by the same shape.
    private func glassBand(width: CGFloat, height: CGFloat, half: CGFloat, alignment: Alignment) -> some View {
        let shape = EarMaskShape(side: side, notchHalf: half)
        let bandWidth = width + Theme.shoulderRadius + half
        let spring = Animation.spring(duration: Theme.earDuration, bounce: 0)
        return ZStack(alignment: alignment) {
            GlassFill(
                tinted: model.prefs.glassTint == .color, blackFade: model.prefs.clearBlackFade,
                colors: model.palette(for: side).map { Color(nsColor: $0) }, side: side, notchHalf: half,
                shape: shape
            )
            .frame(width: bandWidth, height: height)
            .animation(spring, value: bandWidth)

            content(width: width, height: height, half: half)
                .mask(alignment: alignment) {
                    shape
                        .frame(width: bandWidth, height: height)
                        .animation(spring, value: bandWidth)
                }
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

/// Native Liquid Glass shaped like the ear, in any combination of:
///  - tint: clear, or tinted with the cover's colors (lighter than Aurora);
///  - black: Aurora's black, at the top and towards the notch.
/// Uses the clear glass variant (like Control Center), in its dark
/// appearance so it stays see-through rather than milky.
struct GlassFill: View {
    let tinted: Bool
    let blackFade: Bool
    let colors: [Color]
    let side: NotchSide
    let notchHalf: CGFloat
    let shape: EarMaskShape

    var body: some View {
        GeometryReader { proxy in
            let w = max(proxy.size.width, 1)
            let notchEdge = min(1, notchHalf / w)
            let fadeEnd = min(1, (notchHalf + 28) / w)
            let inner: UnitPoint = side == .left ? .trailing : .leading
            let outer: UnitPoint = side == .left ? .leading : .trailing
            ZStack {
                if tinted {
                    // A wash of the cover's colors along the bottom.
                    shape
                        .fill(LinearGradient(colors: colors, startPoint: inner, endPoint: outer))
                        .opacity(0.32)
                        .mask(
                            LinearGradient(
                                stops: [.init(color: .clear, location: 0.3), .init(color: .white, location: 1)],
                                startPoint: .top, endPoint: .bottom))
                }
                if blackFade {
                    // Aurora's black: towards the notch, and from the top.
                    shape.fill(
                        LinearGradient(
                            stops: [
                                .init(color: .black, location: 0),
                                .init(color: .black.opacity(0.75), location: notchEdge * 0.7),
                                .init(color: .black.opacity(0.35), location: notchEdge),
                                .init(color: .black.opacity(0), location: fadeEnd),
                            ], startPoint: inner, endPoint: outer))
                    shape.fill(
                        LinearGradient(
                            stops: [
                                .init(color: .black, location: 0),
                                .init(color: .black.opacity(0.85), location: 0.38),
                                .init(color: .black.opacity(0.05), location: 1),
                            ], startPoint: .top, endPoint: .bottom))
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            // Clear variant: the strongest lensing. Interactive: native
            // highlight and flex under the pointer.
            .glassEffect((tinted ? Glass.clear.tint(colors[0].opacity(0.25)) : .clear).interactive(), in: shape)
        }
        // Dark appearance: see-through without the milky white haze.
        .environment(\.colorScheme, .dark)
        .animation(.smooth(duration: 0.3), value: blackFade)
        .animation(.smooth(duration: 0.3), value: tinted)
        .animation(.easeInOut(duration: 0.6), value: colors)
    }
}
