import AppKit

/// Measures text as the ears draw it (same `EarFont`), so ears can hug their
/// content. Cached: titles and names change rarely.
enum TextWidth {
    private static var cache: [String: CGFloat] = [:]

    static func of(_ text: String, _ style: EarFont) -> CGFloat {
        let key = "\(style.size)|\(style.weight)|\(style.mono)|\(style.tabular)|\(text)"
        if let width = cache[key] { return width }
        let font = style.nsFont
        let width = ceil((text as NSString).size(withAttributes: [.font: font]).width) + 2
        if cache.count > 200 { cache.removeAll() }
        cache[key] = width
        return width
    }
}
