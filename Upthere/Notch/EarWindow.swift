import AppKit
import QuartzCore
import SwiftUI

/// One side of the notch: a panel showing a fixed-size, notch-anchored
/// container whose visible shape is a CAShapeLayer mask.
///
/// Opening and closing only animate the mask path: a critically damped
/// spring on the render server at the display's native refresh rate. SwiftUI
/// lays content out once per state change and never animates geometry, and
/// content anchored next to the notch never moves, so nothing can drift or
/// jump. The panel grows before an opening and shrinks after a closing; the
/// container is pinned to the notch, so resizing never moves what's shown.
final class EarWindow {
    let panel = NotchPanel()
    private let side: NotchSide
    private let container: EarContainerView
    private let mask = CAShapeLayer()
    private var shrinkTask: Task<Void, Never>?

    private var geometry: NotchGeometry?
    private var containerWidth: CGFloat = 0
    private var maxEar: CGFloat = 0
    /// Off for the Glass theme: SwiftUI shapes the glass and clips the
    /// content itself (so the glass rim follows the ear), and the layer
    /// mask just bounds the widest ear.
    private var layerMaskAnimates = true
    /// Ear width the mask is heading to.
    private var ear: CGFloat = 0
    /// Ear width the panel frame currently covers.
    private var visibleEar: CGFloat = 0

    init(side: NotchSide, root: EarRootView) {
        self.side = side
        let host = NotchHostingView(rootView: root)
        host.sizingOptions = []
        container = EarContainerView(host: host)
        container.autoresizingMask = side == .left ? [.minXMargin] : [.maxXMargin]
        mask.fillColor = NSColor.black.cgColor
        container.layer?.mask = mask

        let content = NSView()
        content.addSubview(container)
        panel.contentView = content
    }

    /// Lays out for a screen. `maxEar` is the widest the ear can get.
    func configure(geometry: NotchGeometry, maxEar: CGFloat, layerMask: Bool) {
        self.geometry = geometry
        self.maxEar = maxEar
        layerMaskAnimates = layerMask
        let width = geometry.notchWidth / 2 + maxEar + EarMask.shoulderRadius
        containerWidth = width
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let content = panel.contentView!
        container.frame = CGRect(
            x: side == .left ? content.bounds.width - width : 0, y: 0, width: width, height: geometry.height)
        mask.frame = CGRect(x: 0, y: 0, width: width, height: geometry.height)
        mask.removeAllAnimations()
        mask.path = path(ear: layerMask ? ear : maxEar)
        CATransaction.commit()
        place(ear: max(ear, visibleEar))
    }

    func setEar(_ newEar: CGFloat, animated: Bool = true) {
        guard newEar != ear else { return }
        ear = newEar
        shrinkTask?.cancel()

        // Grow the window first so the mask never animates into clipped space.
        if newEar > visibleEar { place(ear: newEar) }

        let spring = CASpringAnimation(perceptualDuration: Theme.earDuration, bounce: 0)
        let settle: TimeInterval = animated ? spring.settlingDuration : 0
        guard layerMaskAnimates else {
            scheduleShrink(after: settle, newEar: newEar)
            return
        }
        let target = path(ear: newEar)
        if animated {
            spring.keyPath = "path"
            spring.fromValue = mask.presentation()?.path ?? mask.path
            spring.toValue = target
            spring.duration = spring.settlingDuration
            spring.preferredFrameRateRange = Self.nativeFrameRate(for: geometry)
            mask.add(spring, forKey: "path")
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        mask.path = target
        CATransaction.commit()

        scheduleShrink(after: settle, newEar: newEar)
    }

    private func scheduleShrink(after settle: TimeInterval, newEar: CGFloat) {
        guard newEar < visibleEar else { return }
        shrinkTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(min(settle, 0.8)))
            guard !Task.isCancelled, let self else { return }
            self.place(ear: self.ear)
        }
    }

    static func nativeFrameRate(for geometry: NotchGeometry?) -> CAFrameRateRange {
        let screen = NSScreen.screens.first { $0.frame == geometry?.screenFrame } ?? NSScreen.main
        let maximum = Float(max(60, screen?.maximumFramesPerSecond ?? 120))
        return CAFrameRateRange(minimum: 60, maximum: maximum, preferred: maximum)
    }

    private func path(ear: CGFloat) -> CGPath {
        EarMask.path(
            side: side, width: containerWidth, height: geometry?.height ?? 0,
            notchHalf: (geometry?.notchWidth ?? 0) / 2, ear: ear)
    }

    /// Sizes the panel to show the notch half plus `ear` (and its shoulder).
    private func place(ear: CGFloat) {
        guard let g = geometry else { return }
        visibleEar = ear
        let half = g.notchWidth / 2
        let extent = ear > 0 ? ear + EarMask.shoulderRadius : 0
        let width = half + extent
        let x = side == .left ? g.notchRect.minX - extent : g.notchRect.midX
        let frame = CGRect(x: x, y: g.screenFrame.maxY - g.height, width: width, height: g.height).integral
        guard frame.width >= 1 else {
            panel.orderOut(nil)
            return
        }
        if panel.frame != frame { panel.setFrame(frame, display: true) }
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    var contentView: NSView { container }
}

/// Fixed-size, layer-backed container holding the SwiftUI content.
private final class EarContainerView: NSView {
    init(host: NSView) {
        super.init(frame: .zero)
        wantsLayer = true
        host.frame = bounds
        host.autoresizingMask = [.width, .height]
        addSubview(host)
    }

    required init?(coder: NSCoder) { fatalError() }
}
