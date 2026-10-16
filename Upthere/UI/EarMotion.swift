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
