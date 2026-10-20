import AppKit
import SwiftUI

/// Colours are picked in OKLCH (perceptual lightness, chroma, hue) and
/// written out as Display P3, which every notched Mac shows. Chroma is
/// pulled in until the colour fits the gamut, so a hue never clips.
struct OKLCH: Equatable, Sendable {
    var l: Double
    var c: Double
    /// Degrees.
    var h: Double

    nonisolated init(_ l: Double, _ c: Double, _ h: Double) {
        self.l = l
        self.c = c
        self.h = h
    }

    nonisolated var nsColor: NSColor { nsColor(alpha: 1) }

    nonisolated func nsColor(alpha: Double) -> NSColor {
        let (r, g, b) = Self.p3(fitted)
        return NSColor(displayP3Red: Self.encode(r), green: Self.encode(g), blue: Self.encode(b), alpha: alpha)
    }

    nonisolated var color: Color { Color(nsColor: nsColor) }

    nonisolated func with(l: Double? = nil, c: Double? = nil, h: Double? = nil) -> OKLCH {
        OKLCH(l ?? self.l, c ?? self.c, h ?? self.h)
    }

    nonisolated func rotated(by degrees: Double) -> OKLCH {
        var hue = (h + degrees).truncatingRemainder(dividingBy: 360)
        if hue < 0 { hue += 360 }
        return with(h: hue)
    }

    /// The same colour with chroma reduced just enough to fit Display P3.
    nonisolated var fitted: OKLCH {
        if Self.inGamut(self) { return self }
        var lo = 0.0, hi = c
        for _ in 0..<20 {
            let mid = (lo + hi) / 2
            if Self.inGamut(with(c: mid)) { lo = mid } else { hi = mid }
        }
        return with(c: lo)
    }

    /// Any colour, read back as OKLCH (e.g. a pixel from a cover).
    nonisolated init?(_ color: NSColor) {
        guard let srgb = color.usingColorSpace(.sRGB) else { return nil }
        let r = Self.decode(srgb.redComponent), g = Self.decode(srgb.greenComponent), b = Self.decode(srgb.blueComponent)
        let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
        let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
        let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
        let lightness = 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s
        let a = 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s
        let bb = 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s
        var hue = atan2(bb, a) * 180 / .pi
        if hue < 0 { hue += 360 }
        self.init(lightness, hypot(a, bb), hue)
    }

    // MARK: Conversion

    /// OKLCH → linear sRGB.
    nonisolated private static func linearSRGB(_ c: OKLCH) -> (Double, Double, Double) {
        let a = c.c * cos(c.h * .pi / 180), b = c.c * sin(c.h * .pi / 180)
        let l = pow(c.l + 0.3963377774 * a + 0.2158037573 * b, 3)
        let m = pow(c.l - 0.1055613458 * a - 0.0638541728 * b, 3)
        let s = pow(c.l - 0.0894841775 * a - 1.2914855480 * b, 3)
        return (
            4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
            -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
            -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s
        )
    }

    /// OKLCH → linear Display P3.
    nonisolated private static func p3(_ c: OKLCH) -> (Double, Double, Double) {
        let (r, g, b) = linearSRGB(c)
        return (
            0.8224621 * r + 0.1775380 * g,
            0.0331941 * r + 0.9668058 * g,
            0.0170827 * r + 0.0723974 * g + 0.9105199 * b
        )
    }

    nonisolated private static func inGamut(_ c: OKLCH) -> Bool {
        let (r, g, b) = p3(c)
        return [r, g, b].allSatisfy { $0 >= -0.0001 && $0 <= 1.0001 }
    }

    /// Linear → gamma-encoded (P3 and sRGB share the transfer curve).
    nonisolated private static func encode(_ x: Double) -> CGFloat {
        let x = min(1, max(0, x))
        return CGFloat(x <= 0.0031308 ? 12.92 * x : 1.055 * pow(x, 1 / 2.4) - 0.055)
    }

    nonisolated private static func decode(_ x: CGFloat) -> Double {
        let x = Double(x)
        return x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4)
    }
}

extension Theme {
    // MARK: Status colours
    // A matched set: same lightness and chroma, only the hue differs, so no
    // state looks louder than another just because of its colour.

    private static let statusL = 0.77
    private static let statusC = 0.13

    /// Claude needs permission.
    static let permissionTone = OKLCH(statusL, statusC, 75)
    /// Claude is asking you something: the same yellow as a permission,
    /// like the Claude app's "needs your input" dot. The ✋ / ? marks tell
    /// the two apart, so colour is never the only signal.
    static let inputTone = permissionTone
    /// Finished.
    static let successTone = OKLCH(statusL, statusC, 150)
    /// A limit is nearly used up.
    static let dangerTone = OKLCH(statusL, statusC, 25)

    static let amber = permissionTone.nsColor
    static let input = inputTone.nsColor
    static let success = successTone.color
    static let danger = dangerTone.color
    /// Error text in the Settings window: the system red, which stays
    /// readable on both the light and dark window backgrounds (the notch
    /// tokens above are tuned for black).
    static let settingsError = Color(nsColor: .systemRed)

    // MARK: Neutrals
    // White on black at a few fixed strengths. Every translucent white in
    // the notch comes from here.

    enum Ink {
        /// A barely-there wash (a hovered piece's background).
        static let faint = Color.white.opacity(0.07)
        /// Placeholders (a cover that hasn't loaded).
        static let placeholder = Color.white.opacity(0.12)
        /// Tracks behind progress, rings and dividers.
        static let track = Color.white.opacity(0.16)
        /// A control under the pointer.
        static let hover = Color.white.opacity(0.14)
        /// A control being pressed.
        static let pressed = Color.white.opacity(0.22)
        /// Icons that aren't the focus (pager arrows, +).
        static let icon = Color.white.opacity(0.85)
        /// Placeholder glyphs.
        static let glyph = Color.white.opacity(0.55)
        /// Small count badges with dark text on them.
        static let badge = Color.white.opacity(0.7)

        static let hoverOpacity = 0.14
        static let pressedOpacity = 0.22
        static let trackOpacity = 0.16
    }

    // MARK: Palettes

    /// Ear tints for each Claude state: the base, then two neighbours a
    /// little darker and lighter along the hue, for the Aurora gradient.
    static func gradient(from base: OKLCH) -> [NSColor] {
        [base.nsColor, base.rotated(by: -24).with(l: base.l - 0.05).nsColor, base.rotated(by: 18).with(l: base.l + 0.06).nsColor]
    }

    /// Six timer colours: one lightness and chroma, hues spread around the
    /// wheel so neighbours are easy to tell apart.
    static let timerTones: [OKLCH] = [235, 58, 142, 345, 300, 95].map { OKLCH(0.80, 0.12, $0) }
}
