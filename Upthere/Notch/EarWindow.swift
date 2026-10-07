import AppKit
import QuartzCore
import SwiftUI

/// One side of the notch: a panel showing a fixed-size, notch-anchored
/// container whose visible shape is a Core Animation mask.
///
/// Opening and closing only animate the mask path, on the render server at
/// the display's native refresh rate; SwiftUI lays the content out once per
/// state change, never per frame. The panel frame grows before an opening
/// and shrinks after a closing, and since the container is pinned to the
/// notch, resizing the window never moves what's on screen.
final class EarWindow {
    let panel = NotchPanel()
    private let side: NotchSide
    private let container: EarContainerView
    private let mask = CAShapeLayer()
    private var shrinkTask: Task<Void, Never>?

    private var geometry: NotchGeometry?
    private var containerWidth: CGFloat = 0
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
    func configure(geometry: NotchGeometry, maxEar: CGFloat) {
        self.geometry = geometry
        let width = geometry.notchWidth / 2 + maxEar + EarMask.shoulderRadius
        containerWidth = width
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let content = panel.contentView!
        container.frame = CGRect(
            x: side == .left ? content.bounds.width - width : 0, y: 0, width: width, height: geometry.height)
        mask.frame = CGRect(x: 0, y: 0, width: width, height: geometry.height)
        mask.removeAllAnimations()
        mask.path = path(ear: ear)
        CATransaction.commit()
        place(ear: max(ear, visibleEar))
    }

    func setEar(_ newEar: CGFloat, animated: Bool) {
        guard newEar != ear else { return }
        let opening = newEar > ear
        ear = newEar
        shrinkTask?.cancel()

        // Grow the window first so the mask never animates into clipped space.
        if newEar > visibleEar { place(ear: newEar) }

        let target = path(ear: newEar)
        var settle: TimeInterval = 0
        if animated {
            let spring = CASpringAnimation(perceptualDuration: opening ? 0.42 : 0.32, bounce: opening ? 0.2 : 0)
            spring.keyPath = "path"
            spring.fromValue = mask.presentation()?.path ?? mask.path
            spring.toValue = target
            spring.duration = spring.settlingDuration
            spring.preferredFrameRateRange = Self.nativeFrameRate(for: geometry)
            mask.add(spring, forKey: "path")
            settle = spring.settlingDuration
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        mask.path = target
        CATransaction.commit()

        guard newEar < visibleEar else { return }
        shrinkTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(min(settle, 0.8)))
            guard !Task.isCancelled, let self else { return }
            self.place(ear: self.ear)
        }
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

    static func nativeFrameRate(for geometry: NotchGeometry?) -> CAFrameRateRange {
        let screen = NSScreen.screens.first { $0.frame == geometry?.screenFrame } ?? NSScreen.main
        let maximum = Float(max(60, screen?.maximumFramesPerSecond ?? 120))
        return CAFrameRateRange(minimum: 60, maximum: maximum, preferred: maximum)
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
