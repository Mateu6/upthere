import AppKit
import Observation
import SwiftUI

/// Owns two panels, one per side of the notch (see `EarWindow`), and feeds
/// them the target ear widths. The panels only ever cover the visible ears,
/// keeping the rest of the menu bar clickable.
final class NotchWindowController {
    private let viewModel: NotchViewModel
    private let prefs: Preferences
    private let left: EarWindow
    private let right: EarWindow
    private var screenObserver: NSObjectProtocol?
    private var scrollMonitor: Any?

    init(
        nowPlaying: NowPlayingModel, claude: ClaudeModel, prefs: Preferences, queue: QueueModel, timers: TimerModel,
        actions: NotchActions
    ) {
        self.prefs = prefs
        let screen = ScreenPicker.screen(for: prefs.display) ?? NSScreen.screens[0]
        let model = NotchViewModel(
            nowPlaying: nowPlaying, claude: claude, prefs: prefs, geometry: .make(for: screen), queue: queue,
            timers: timers)
        model.openSettings = actions.openSettings
        model.openTimerInput = actions.openTimerInput
        viewModel = model
        left = EarWindow(side: .left, root: EarRootView(model: model, side: .left, actions: actions))
        right = EarWindow(side: .right, root: EarRootView(model: model, side: .right, actions: actions))

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateScreen(force: false) }
        }
        configure()
        observeLayout()
        observeConfiguration()
        observeCentering()
        installScrollMonitor()
        #if DEBUG
        DebugBridge.install(model: model, actions: actions) { [left, right] in
            [("left", left.contentView), ("right", right.contentView)]
        }
        #endif
    }

    var geometry: NotchGeometry { viewModel.geometry }

    private func configure() {
        let g = viewModel.geometry
        let layerMask = prefs.theme != .clear
        left.configure(geometry: g, maxEar: viewModel.maxEarWidth(room: g.leftRoom), layerMask: layerMask)
        right.configure(geometry: g, maxEar: viewModel.maxEarWidth(room: g.rightRoom), layerMask: layerMask)
        left.setEar(viewModel.leftWidth, animated: false)
        right.setEar(viewModel.rightWidth, animated: false)
    }

    private func updateScreen(force: Bool) {
        guard let screen = ScreenPicker.screen(for: prefs.display) else { return }
        let geometry = NotchGeometry.make(for: screen).centering(offset: viewModel.restingCenterOffset)
        guard force || geometry != viewModel.geometry else { return }
        let old = viewModel.geometry
        viewModel.geometry = geometry
        // Only the virtual notch moved (re-centering): glide there.
        var moved = old
        moved.notchRect.origin.x = geometry.notchRect.origin.x
        if !force, moved == geometry {
            left.slide(to: geometry)
            right.slide(to: geometry)
            return
        }
        configure()
    }

    private func observeLayout() {
        let (l, r) = withObservationTracking {
            (viewModel.leftWidth, viewModel.rightWidth)
        } onChange: { [weak self] in
            // onChange fires before the new value is stored; hop once.
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.observeLayout() } }
        }
        left.setEar(l)
        right.setEar(r)
    }

    /// Notchless screens: keep the resting ears centered as what they show
    /// changes (e.g. music starts while Claude works).
    private func observeCentering() {
        let offset = withObservationTracking { viewModel.restingCenterOffset } onChange: { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.observeCentering() } }
        }
        guard !viewModel.geometry.hasNotch, viewModel.geometry.screenFrame.midX - viewModel.geometry.notchRect.minX != offset
        else { return }
        updateScreen(force: false)
    }

    private func observeConfiguration() {
        withObservationTracking {
            _ = prefs.display
            _ = prefs.maxEarWidth
            _ = prefs.theme
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.updateScreen(force: true)
                    self?.observeConfiguration()
                }
            }
        }
    }

    /// Scroll events over the panels arrive through the app's event queue
    /// even though the panels never become key.
    private func installScrollMonitor() {
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            // Local monitors run on the main thread.
            nonisolated(unsafe) let event = event
            let consumed = MainActor.assumeIsolated { () -> Bool in
                guard let self, let window = event.window else { return false }
                let side: NotchSide
                if window === self.left.panel {
                    side = .left
                } else if window === self.right.panel {
                    side = .right
                } else {
                    return false
                }
                return self.viewModel.scroll(event, side: side)
            }
            return consumed ? nil : event
        }
    }
}
