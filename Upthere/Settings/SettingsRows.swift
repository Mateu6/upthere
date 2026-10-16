import AppKit
import SwiftUI

/// Building blocks shared by the Settings tabs.
enum SettingsLayout {
    static let width: CGFloat = 500
    static let maxHeight: CGFloat = 720
}

extension View {
    /// A Settings tab: grouped form at the window's width, as tall as its
    /// content (the window resizes per tab) up to `maxHeight`, then it scrolls.
    func settingsTab(maxHeight: CGFloat = SettingsLayout.maxHeight) -> some View {
        formStyle(.grouped)
            .scrollBounceBehavior(.basedOnSize)
            .frame(width: SettingsLayout.width)
            .frame(maxHeight: maxHeight)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A problem with the way out next to it.
struct FixRow: View {
    let message: String
    let button: String
    var color: NSColor = Theme.amber
    let action: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color(nsColor: color))
            Text(message).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button(button, action: action).controlSize(.small)
        }
    }
}

struct ErrorText: View {
    let message: String

    var body: some View {
        Text(message).foregroundStyle(Theme.settingsError).font(.caption)
    }
}

/// A footnote under a section.
struct SettingsFooter: View {
    let text: LocalizedStringKey

    var body: some View {
        Text(text).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
    }
}

/// "Connected ✓  [Disconnect]" or a connect button.
struct ConnectionRow: View {
    let title: String
    let connected: Bool
    let connect: String
    let onConnect: () -> Void
    let onDisconnect: () -> Void

    var body: some View {
        LabeledContent(title) {
            if connected {
                Label("Connected", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.success)
                Button("Disconnect", action: onDisconnect)
            } else {
                Button(connect, action: onConnect)
            }
        }
    }
}

enum PrivacySettings {
    static func open(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }
}

struct PlayerLabel: View {
    let bundleID: String

    var body: some View {
        HStack(spacing: 6) {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                    .resizable()
                    .frame(width: 16, height: 16)
                Text(FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: ""))
            } else {
                Text(bundleID)
            }
        }
    }
}

/// Copies a value, then shows a checkmark for a moment so the click is seen.
struct CopyButton: View {
    let value: String
    @State private var copied = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(value, forType: .string)
            copied = true
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                copied = false
            }
        } label: {
            Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                .contentTransition(.symbolEffect(.replace))
        }
        .controlSize(.small)
        .animation(.smooth(duration: 0.2), value: copied)
    }
}
