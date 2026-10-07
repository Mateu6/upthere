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

    init(nowPlaying: NowPlayingModel, claude: ClaudeModel, prefs: Preferences, actions: NotchActions) {
        self.prefs = prefs
        let screen = ScreenPicker.screen(for: prefs.display) ?? NSScreen.screens[0]
        let model = NotchViewModel(nowPlaying: nowPlaying, claude: claude, prefs: prefs, geometry: .make(for: screen))
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
        installScrollMonitor()
        #if DEBUG
        DebugBridge.install(model: model, actions: actions) { [left, right] in
            [("left", left.contentView), ("right", right.contentView)]
        }
        #endif
    }

    private func configure() {
        let g = viewModel.geometry
        left.configure(geometry: g, maxEar: viewModel.maxEarWidth(room: g.leftRoom))
        right.configure(geometry: g, maxEar: viewModel.maxEarWidth(room: g.rightRoom))
        left.setEar(viewModel.leftWidth, animated: false)
        right.setEar(viewModel.rightWidth, animated: false)
    }

    private func updateScreen(force: Bool) {
        guard let screen = ScreenPicker.screen(for: prefs.display) else { return }
        let geometry = NotchGeometry.make(for: screen)
        guard force || geometry != viewModel.geometry else { return }
        viewModel.geometry = geometry
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

    private func observeConfiguration() {
        withObservationTracking {
            _ = prefs.display
            _ = prefs.maxEarWidth
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
