import AppKit
import SwiftUI

/// The Settings window: standard macOS toolbar tabs, one per thing Upthere
/// does plus General and Appearance. The window takes each tab's height and
/// its title follows the selected tab, as in System Settings-era apps.
final class SettingsWindowController {
    private let window: NSWindow
    private let tabs = NSTabViewController()

    init(
        prefs: Preferences, nowPlaying: NowPlayingModel, claude: ClaudeModel, queue: QueueModel,
        calendar: CalendarLogger, reminders: RemindersModel, updater: Updater
    ) {
        tabs.tabStyle = .toolbar
        tabs.transitionOptions = [.crossfade, .allowUserInteraction]
        Self.add("General", symbol: "gearshape", GeneralSettings(prefs: prefs, updater: updater), to: tabs)
        Self.add("Appearance", symbol: "circle.lefthalf.filled", AppearanceSettings(prefs: prefs), to: tabs)
        Self.add("Music", symbol: "music.note", MusicSettings(prefs: prefs, queue: queue), to: tabs)
        Self.add("Claude", symbol: "sparkle", ClaudeSettings(prefs: prefs, claude: claude), to: tabs)
        Self.add("Timers", symbol: "timer", TimerSettings(prefs: prefs, calendar: calendar), to: tabs)
        Self.add("Reminders", symbol: "checklist", ReminderSettings(prefs: prefs, reminders: reminders), to: tabs)

        window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
    }

    func show(tab: String? = nil) {
        if let tab, let index = tabs.tabViewItems.firstIndex(where: { $0.label == tab }) {
            tabs.selectedTabViewItemIndex = index
        }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    private static func add(_ title: String, symbol: String, _ view: some View, to tabs: NSTabViewController) {
        let host = NSHostingController(rootView: view)
        // The window resizes to each tab's height.
        host.sizingOptions = [.preferredContentSize]
        host.title = title
        let item = NSTabViewItem(viewController: host)
        item.label = title
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        tabs.addTabViewItem(item)
    }
}
