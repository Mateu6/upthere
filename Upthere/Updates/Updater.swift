import AppKit
import Observation
import Sparkle

/// Sparkle wrapper. Upthere is a background (LSUIElement) app, so update
/// windows are brought forward explicitly instead of appearing behind
/// whatever the user is working in.
@Observable
final class Updater: NSObject, SPUStandardUserDriverDelegate {
    private(set) var canCheckForUpdates = false
    var automaticallyChecksForUpdates = true {
        didSet { controller.updater.automaticallyChecksForUpdates = automaticallyChecksForUpdates }
    }

    @ObservationIgnored private var controller: SPUStandardUpdaterController!
    @ObservationIgnored private var canCheckObservation: NSKeyValueObservation?

    override init() {
        super.init()
        controller = SPUStandardUpdaterController(
            startingUpdater: false, updaterDelegate: nil, userDriverDelegate: self)
    }

    func start() {
        // Development builds never replace themselves with a release.
        #if !DEBUG
        controller.startUpdater()
        let updater = controller.updater
        automaticallyChecksForUpdates = updater.automaticallyChecksForUpdates
        canCheckObservation = updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
            let canCheck = updater.canCheckForUpdates
            Task { @MainActor in self?.canCheckForUpdates = canCheck }
        }
        #endif
    }

    func checkForUpdates() {
        NSApp.activate()
        controller.checkForUpdates(nil)
    }

    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "–"
    }

    // MARK: SPUStandardUserDriverDelegate

    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        // Updates are rare; showing them right away beats a reminder nobody
        // sees in an app without a Dock icon.
        true
    }

    nonisolated func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState
    ) {
        guard handleShowingUpdate else { return }
        Task { @MainActor in NSApp.activate() }
    }
}
