import CoreGraphics

/// The visible shape of one side: its half of the notch plus the ear.
///
/// The ear's outer bottom corner is rounded and its outer top corner flares
/// into the screen's top edge with a concave shoulder. With the ear closed
/// the shape is just the notch strip, its corner rounding to stay inside the
/// physical notch's curve.
///
/// Every geometry produces the same sequence of path elements, so Core
/// Animation can spring between any two shapes.
nonisolated enum EarMask {
    static let shoulderRadius: CGFloat = 6
    static let earRadius: CGFloat = 10
    static let closedRadius: CGFloat = 12
    private static let kappa: CGFloat = 0.5523

    /// - Parameters:
    ///   - width: container width; the notch center is at its inner edge.
    ///   - ear: ear width, without the shoulder.
    /// Coordinates are bottom-left based (AppKit layers), top edge at `height`.
    static func path(side: NotchSide, width: CGFloat, height h: CGFloat, notchHalf: CGFloat, ear: CGFloat) -> CGPath {
        let e = max(0, ear)
        let rs = max(0.01, min(shoulderRadius, e / 4))
        let target = earRadius + (closedRadius - earRadius) * max(0, 1 - e / 24)
        let rb = max(0.01, min(target, (notchHalf + e) / 2, h / 2))

        // Built for the left side (notch center at x = width), then mirrored.
        let xo = width - notchHalf - e
        let k = kappa
        func p(_ x: CGFloat, _ yFromTop: CGFloat) -> CGPoint {
            CGPoint(x: side == .left ? x : width - x, y: h - yFromTop)
        }
        let path = CGMutablePath()
        path.move(to: p(xo - rs, 0))
        path.addLine(to: p(width, 0))
        path.addLine(to: p(width, h))
        path.addLine(to: p(xo + rb, h))
        path.addCurve(to: p(xo, h - rb), control1: p(xo + rb * (1 - k), h), control2: p(xo, h - rb * (1 - k)))
        path.addLine(to: p(xo, rs))
        path.addCurve(to: p(xo - rs, 0), control1: p(xo, rs * (1 - k)), control2: p(xo - rs * (1 - k), 0))
        path.closeSubpath()
        return path
    }
}
