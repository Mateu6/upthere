import AppKit
import SwiftUI

/// One text style in the ears. Carries both the SwiftUI font (for drawing)
/// and the AppKit font (for `TextWidth`, so ears hug text exactly as drawn).
struct EarFont: Hashable, Sendable {
    let size: CGFloat
    let weight: Font.Weight
    /// SF Mono: every character the same width.
    let mono: Bool
    /// SF with tabular digits: words stay proportional, figures don't jitter.
    var tabular = false

    var font: Font {
        let font = Font.system(size: size, weight: weight, design: mono ? .monospaced : .default)
        return tabular ? font.monospacedDigit() : font
    }

    var nsFont: NSFont {
        let w = Self.nsWeight(weight)
        if mono { return .monospacedSystemFont(ofSize: size, weight: w) }
        return tabular ? .monospacedDigitSystemFont(ofSize: size, weight: w) : .systemFont(ofSize: size, weight: w)
    }

    private static func nsWeight(_ weight: Font.Weight) -> NSFont.Weight {
        switch weight {
        case .regular: .regular
        case .medium: .medium
        case .semibold: .semibold
        case .bold: .bold
        default: .regular
        }
    }
}

extension Theme {
    /// The ears' type scale ("Instrument", docs/design-language.md): three
    /// sizes, 12 · 10.5 · 9, plus SF Mono for figures. Hierarchy comes from
    /// weight and opacity, not more sizes.
    enum TextStyle {
        /// What it is: project, track, plan name. Also one-line rows.
        static let title = EarFont(size: 12, weight: .medium, mono: false)
        /// What's happening: status line, artist, hints.
        static let body = EarFont(size: 10.5, weight: .regular, mono: false)
        /// A name in a dense row: timer labels, Up Next titles.
        static let label = EarFont(size: 10.5, weight: .medium, mono: false)
        /// Smallest supporting text (Up Next artist).
        static let caption = EarFont(size: 9, weight: .regular, mono: false)
        /// Counts on badges ("+2").
        static let badge = EarFont(size: 9, weight: .bold, mono: false)
        /// Times and readouts. Monospaced so they never jitter.
        static let figure = EarFont(size: 10, weight: .medium, mono: true)
        /// Usage chips ("12.6M tok · ctx 27%"): mostly words, so SF with
        /// tabular digits. Mono here is too wide and crowds the status line.
        static let chip = EarFont(size: 10.5, weight: .regular, mono: false, tabular: true)
        /// A running timer's main readout.
        static let readout = EarFont(size: 12, weight: .medium, mono: true)
    }
}
