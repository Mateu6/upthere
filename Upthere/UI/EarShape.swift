import SwiftUI

/// One ear. The inner side meets the notch; the outer bottom corner is
/// rounded; the outer top corner flares out into the screen's top edge with a
/// concave "shoulder", like the physical notch does.
///
/// The shoulder lives inside `rect` (its outermost `shoulderRadius` points),
/// so callers widen the ear's frame by the shoulder radius.
///
/// With `notchExtension`, the shape also covers that much of the notch at its
/// inner edge, so ear and notch strip are one seamless shape. With the ear
/// closed it shrinks to the notch strip, its corner rounding to stay inside
/// the physical notch's curve.
struct EarShape: Shape {
    var side: NotchSide
    var notchExtension: CGFloat = 0
    var bottomRadius: CGFloat = 10  // Theme.earRadius
    var shoulderRadius: CGFloat = 6  // Theme.shoulderRadius
    var closedRadius: CGFloat = 12  // Theme.notchCornerRadius

    func path(in rect: CGRect) -> Path {
        let w = rect.width
        let h = rect.height
        guard w > 0.5, h > 0.5 else { return Path() }
        let ear = max(0, w - notchExtension)
        let rs = min(shoulderRadius, ear / 4)
        // Blend from the ear's radius to the notch's as the ear closes.
        let target = bottomRadius + (closedRadius - bottomRadius) * max(0, 1 - ear / 24)
        let rb = max(0, min(target, (w - rs) / 2, h / 2))

        var p = Path()
        p.move(to: CGPoint(x: 0, y: 0))
        p.addLine(to: CGPoint(x: w, y: 0))
        p.addLine(to: CGPoint(x: w, y: h))
        p.addLine(to: CGPoint(x: rs + rb, y: h))
        p.addArc(tangent1End: CGPoint(x: rs, y: h), tangent2End: CGPoint(x: rs, y: 0), radius: rb)
        p.addLine(to: CGPoint(x: rs, y: rs))
        p.addArc(tangent1End: CGPoint(x: rs, y: 0), tangent2End: CGPoint(x: 0, y: 0), radius: rs)
        p.closeSubpath()

        // Paths are drawn for the left ear; mirror for the right.
        guard side == .right else { return p.offsetBy(dx: rect.minX, dy: rect.minY) }
        return p
            .applying(CGAffineTransform(scaleX: -1, y: 1).translatedBy(x: -w, y: 0))
            .offsetBy(dx: rect.minX, dy: rect.minY)
    }
}
