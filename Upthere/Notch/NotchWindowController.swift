import AppKit
import Observation
import SwiftUI

/// Owns two panels, one per ear. Each covers its ear plus half of the notch
/// and is anchored at the notch: the left panel grows leftwards, the right
/// one rightwards, so content never shifts when a window resizes. Window
/// frames always hug the ears, keeping the rest of the menu bar clickable.
final class NotchWindowController {
    private let viewModel: NotchViewModel
    private let prefs: Preferences
    private let left: EarWindow
    private let right: EarWindow
    private var shrinkTask: Task<Void, Never>?
    private var screenObserver: NSObjectProtocol?

    /// Slightly longer than the ear spring, so shrinking ears aren't clipped.
    private static let shrinkDelay: Duration = .milliseconds(520)

    init(nowPlaying: NowPlayingModel, claude: ClaudeModel, prefs: Preferences, actions: NotchActions) {
        self.prefs = prefs
        let screen = ScreenPicker.screen(for: prefs.display) ?? NSScreen.screens[0]
        let model = NotchViewModel(nowPlaying: nowPlaying, claude: claude, prefs: prefs, geometry: .make(for: screen))
        viewModel = model
        left = EarWindow(root: EarRootView(model: model, side: .left, actions: actions))
        right = EarWindow(root: EarRootView(model: model, side: .right, actions: actions))

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateScreen() }
        }
        observeLayout()
        observeDisplayPreference()
        apply(left: model.leftWidth, right: model.rightWidth)
        #if DEBUG
        DebugBridge.install(model: model, actions: actions) { [left, right] in
            [("left", left.panel.contentView!), ("right", right.panel.contentView!)]
        }
        #endif
    }

    private func updateScreen() {
        guard let screen = ScreenPicker.screen(for: prefs.display) else { return }
        let geometry = NotchGeometry.make(for: screen)
        guard geometry != viewModel.geometry else { return }
        viewModel.geometry = geometry
        apply(left: viewModel.leftWidth, right: viewModel.rightWidth)
    }

    private func observeLayout() {
        withObservationTracking {
            _ = viewModel.leftWidth
            _ = viewModel.rightWidth
        } onChange: { [weak self] in
            // onChange fires before the new value is stored; hop once.
            Task { @MainActor [weak self] in
                self?.layoutChanged()
                self?.observeLayout()
            }
        }
    }

    private func observeDisplayPreference() {
        withObservationTracking {
            _ = prefs.display
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.updateScreen()
                self?.observeDisplayPreference()
            }
        }
    }

    /// Grow immediately; shrink only after the ears finished closing.
    private func layoutChanged() {
        shrinkTask?.cancel()
        let l = viewModel.leftWidth
        let r = viewModel.rightWidth
        apply(left: max(l, left.extent), right: max(r, right.extent))
        guard l < left.extent || r < right.extent else { return }
        shrinkTask = Task { [weak self] in
            try? await Task.sleep(for: Self.shrinkDelay)
            guard !Task.isCancelled, let self else { return }
            self.apply(left: self.viewModel.leftWidth, right: self.viewModel.rightWidth)
        }
    }

    private func apply(left leftExtent: CGFloat, right rightExtent: CGFloat) {
        let g = viewModel.geometry
        let half = g.notchWidth / 2
        let y = g.screenFrame.maxY - g.height
        left.extent = leftExtent
        right.extent = rightExtent
        left.place(CGRect(x: g.notchRect.minX - leftExtent, y: y, width: leftExtent + half, height: g.height))
        right.place(CGRect(x: g.notchRect.midX, y: y, width: rightExtent + half, height: g.height))
    }
}

/// One ear's panel and hosting view.
private final class EarWindow {
    let panel = NotchPanel()
    var extent: CGFloat = 0

    init(root: EarRootView) {
        let host = NotchHostingView(rootView: root)
        host.sizingOptions = []
        panel.contentView = host
    }

    func place(_ frame: CGRect) {
        let frame = frame.integral
        guard frame.width >= 1 else {
            panel.orderOut(nil)
            return
        }
        if panel.frame != frame { panel.setFrame(frame, display: true) }
        if !panel.isVisible { panel.orderFrontRegardless() }
    }
}
