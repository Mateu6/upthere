import SwiftUI

extension View {
    /// Springs `value` (an ear or piece width) with the ear's open spring
    /// when it grows and its quicker close spring when it shrinks, matching
    /// the mask in `EarWindow`. SwiftUI springs keep their velocity when
    /// retargeted, so a reversal mid-way carries on smoothly.
    func earSpring(value: CGFloat) -> some View {
        modifier(EarSpringModifier(value: value))
    }
}

extension AnyTransition {
    /// New content in an ear: blurs in while sliding a few points outwards
    /// from the notch, as if carried by the opening ear. It leaves with a
    /// plain blur, so nothing travels while the ear closes. Under Reduce
    /// Motion the slide goes and the blur stays.
    static func earContent(_ side: NotchSide) -> AnyTransition {
        let slide = Motion.reduced ? 0 : Theme.contentSlide
        let towardsNotch = side == .left ? slide : -slide
        return .asymmetric(
            insertion: AnyTransition(.blurReplace).combined(with: .offset(x: towardsNotch)),
            removal: AnyTransition(.blurReplace))
    }
}

extension View {
    /// For things at an ear's far end (the music controls): they arrive
    /// where the edge is now and travel out with it on the ear's spring, so
    /// they never show up before the ear has made room for them. Under
    /// Reduce Motion they just appear in place.
    func ridesEarEdge(_ side: NotchSide, model: NotchViewModel) -> some View {
        modifier(RidesEarEdge(side: side, lag: edgeLag(side, model: model), clips: false))
    }

    /// For what sits just inside those far-end things (the track title):
    /// its far end is uncovered at the same pace, so they never overlap.
    func revealedByEarEdge(_ side: NotchSide, model: NotchViewModel) -> some View {
        modifier(RidesEarEdge(side: side, lag: edgeLag(side, model: model), clips: true))
    }

    /// How far the ear's edge still has to travel.
    private func edgeLag(_ side: NotchSide, model: NotchViewModel) -> CGFloat {
        let target = side == .left ? model.leftWidth : model.rightWidth
        return Motion.reduced ? 0 : max(0, target - model.presentedEarWidth(side))
    }
}

private struct RidesEarEdge: ViewModifier {
    let side: NotchSide
    let clips: Bool
    /// Set once, when the view first appears; later changes are ignored.
    @State private var lag: CGFloat

    init(side: NotchSide, lag: CGFloat, clips: Bool) {
        self.side = side
        self.clips = clips
        _lag = State(initialValue: lag)
    }

    func body(content: Content) -> some View {
        Group {
            if clips {
                content.mask(alignment: side == .right ? .leading : .trailing) {
                    Rectangle().padding(side == .right ? .trailing : .leading, lag)
                }
            } else {
                content.offset(x: side == .left ? lag : -lag)
            }
        }
        .onAppear {
            guard lag != 0 else { return }
            withAnimation(Theme.earSpring(opening: true)) { lag = 0 }
        }
    }
}

private struct EarSpringModifier: ViewModifier {
    let value: CGFloat
    /// The value seen last time, to tell growing from shrinking at the
    /// moment the change is applied (a plain reference, so updating it
    /// doesn't trigger another render).
    @State private var last = Box()

    func body(content: Content) -> some View {
        let opening = value >= last.value
        last.value = value
        return content.animation(Theme.earSpring(opening: opening), value: value)
    }

    private final class Box {
        var value: CGFloat = 0
    }
}
