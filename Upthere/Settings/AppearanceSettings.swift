import SwiftUI

struct AppearanceSettings: View {
    @Bindable var prefs: Preferences

    var body: some View {
        Form {
            Section {
                ThemePickers(
                    title: prefs.separateNotchlessTheme ? "Theme with a notch" : "Theme",
                    theme: $prefs.theme, tint: $prefs.glassTint, fade: $prefs.clearBlackFade)
            }

            Section("Screens without a notch") {
                Toggle("Different theme on screens without a notch", isOn: $prefs.separateNotchlessTheme.animation())
                if prefs.separateNotchlessTheme {
                    ThemePickers(
                        title: "Theme without a notch", theme: $prefs.notchlessTheme, tint: $prefs.notchlessGlassTint,
                        fade: $prefs.notchlessBlackFade)
                }
                Picker("Center piece without a notch", selection: $prefs.centerPiece) {
                    ForEach(CenterPiece.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .help("On screens without a notch, what sits in the middle when Claude, music and timers all show")
            }
        }
        .settingsTab()
    }
}

/// A theme picker with its Glass options (shown for the Glass theme).
private struct ThemePickers: View {
    let title: String
    @Binding var theme: NotchTheme
    @Binding var tint: GlassTint
    @Binding var fade: Bool

    var body: some View {
        Picker(title, selection: $theme.animation()) {
            ForEach(NotchTheme.allCases) { Text($0.title).tag($0) }
        }
        if theme == .clear {
            Picker("Glass", selection: $tint) {
                ForEach(GlassTint.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            Toggle("Black gradient (like Aurora)", isOn: $fade)
        }
    }
}
