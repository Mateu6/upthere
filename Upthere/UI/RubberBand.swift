import CoreGraphics

/// How far content moves when pulled past an edge: iOS's rubber band,
/// `c·x·d / (d + c·x)`. Near the edge it follows at about `c` of the pull,
/// resists more the further it goes, and never travels past `d`.
enum RubberBand {
    /// Apple uses 0.55 for touch; a pointer pulls a little stiffer.
    static let trackpad: CGFloat = 0.4

    /// - Parameters:
    ///   - x: how far the pull is past the edge (signed).
    ///   - d: the view's size along that axis, the most it can ever move.
    static func offset(_ x: CGFloat, limit d: CGFloat, c: CGFloat = trackpad) -> CGFloat {
        guard d > 0 else { return 0 }
        let pull = abs(x)
        let moved = c * pull * d / (d + c * pull)
        return x < 0 ? -moved : moved
    }
}
