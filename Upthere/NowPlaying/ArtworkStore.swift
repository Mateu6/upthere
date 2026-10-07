import AppKit
import ImageIO

nonisolated struct Artwork: @unchecked Sendable, Equatable {
    let image: NSImage
    let tint: NSColor
    /// 3 vivid colors from the cover, for gradients and the glow.
    let palette: [NSColor]

    static func == (lhs: Artwork, rhs: Artwork) -> Bool { lhs.image === rhs.image }
}

/// Decodes and downsamples artwork off the main thread, keeping a small LRU.
final class ArtworkStore {
    private var cache: [String: Artwork] = [:]
    private var order: [String] = []
    private var inFlight: Set<String> = []
    private let capacity = 8
    /// Points; images are decoded at 2x this.
    private let maxSide: CGFloat = 96

    var onLoaded: ((String) -> Void)?

    func artwork(for key: String) -> Artwork? { cache[key] }

    func has(_ key: String) -> Bool { cache[key] != nil || inFlight.contains(key) }

    func ingest(key: String, data: Data) {
        inFlight.insert(key)
        let maxPixels = maxSide * 2
        Task.detached(priority: .utility) {
            let artwork = Self.decode(data, maxPixels: maxPixels)
            await MainActor.run { self.store(key: key, artwork: artwork) }
        }
    }

    func ingest(key: String, url: URL) {
        guard !has(key) else { return }
        inFlight.insert(key)
        Task {
            let data = try? await URLSession.shared.data(from: url).0
            guard let data else { inFlight.remove(key); return }
            ingest(key: key, data: data)
        }
    }

    private func store(key: String, artwork: Artwork?) {
        inFlight.remove(key)
        guard let artwork else { return }
        cache[key] = artwork
        order.removeAll { $0 == key }
        order.append(key)
        while order.count > capacity { cache.removeValue(forKey: order.removeFirst()) }
        onLoaded?(key)
    }

    nonisolated private static func decode(_ data: Data, maxPixels: CGFloat) -> Artwork? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let image = NSImage(cgImage: cg, size: NSSize(width: cg.width / 2, height: cg.height / 2))
        let tint = averageColor(cg)
        return Artwork(image: image, tint: tint, palette: palette(cg, fallback: tint))
    }

    /// Dominant hues by weighted hue histogram over a 24×24 thumbnail,
    /// ignoring greys; boosted so they glow on black.
    nonisolated static func palette(_ image: CGImage, fallback: NSColor, count: Int = 3) -> [NSColor] {
        let side = 24
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        guard
            let ctx = CGContext(
                data: &pixels, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return derived(from: fallback, count: count) }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))

        let bins = 18
        var weight = [CGFloat](repeating: 0, count: bins)
        var sums = [(h: CGFloat, s: CGFloat, b: CGFloat)](repeating: (0, 0, 0), count: bins)
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let color = NSColor(
                srgbRed: CGFloat(pixels[i]) / 255, green: CGFloat(pixels[i + 1]) / 255,
                blue: CGFloat(pixels[i + 2]) / 255, alpha: 1)
            var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            color.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
            guard s > 0.18, b > 0.18 else { continue }
            let bin = min(bins - 1, Int(h * CGFloat(bins)))
            let w = s * b
            weight[bin] += w
            sums[bin].h += h * w
            sums[bin].s += s * w
            sums[bin].b += b * w
        }

        var picked: [NSColor] = []
        var usedBins: [Int] = []
        for bin in weight.indices.sorted(by: { weight[$0] > weight[$1] }) where weight[bin] > 0.4 {
            // Skip hues adjacent to one already picked.
            if usedBins.contains(where: { min(abs($0 - bin), bins - abs($0 - bin)) < 2 }) { continue }
            let w = weight[bin]
            picked.append(vivid(hue: sums[bin].h / w, saturation: sums[bin].s / w, brightness: sums[bin].b / w))
            usedBins.append(bin)
            if picked.count == count { break }
        }
        if picked.isEmpty { return derived(from: fallback, count: count) }
        while picked.count < count {
            picked.append(shifted(picked[picked.count - 1], by: 0.08))
        }
        return picked
    }

    nonisolated private static func vivid(hue: CGFloat, saturation: CGFloat, brightness: CGFloat) -> NSColor {
        NSColor(hue: hue, saturation: min(1, max(0.5, saturation * 1.15)), brightness: max(0.85, brightness), alpha: 1)
    }

    nonisolated private static func shifted(_ color: NSColor, by amount: CGFloat) -> NSColor {
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.usingColorSpace(.sRGB)?.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return NSColor(hue: (h + amount).truncatingRemainder(dividingBy: 1), saturation: s, brightness: b, alpha: 1)
    }

    nonisolated static func derived(from color: NSColor, count: Int) -> [NSColor] {
        (0..<count).map { shifted(color, by: CGFloat($0) * 0.09) }
    }

    /// Average color, nudged brighter and more saturated so it reads on black.
    nonisolated private static func averageColor(_ image: CGImage) -> NSColor {
        var pixel = [UInt8](repeating: 0, count: 4)
        let space = CGColorSpaceCreateDeviceRGB()
        guard
            let ctx = CGContext(
                data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return .white }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let color = NSColor(
            srgbRed: CGFloat(pixel[0]) / 255, green: CGFloat(pixel[1]) / 255, blue: CGFloat(pixel[2]) / 255, alpha: 1)
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return NSColor(hue: h, saturation: min(1, s * 1.3), brightness: max(0.75, b), alpha: 1)
    }
}
