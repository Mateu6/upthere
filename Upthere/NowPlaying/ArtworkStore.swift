import AppKit
import ImageIO

nonisolated struct Artwork: @unchecked Sendable, Equatable {
    let image: NSImage
    let tint: NSColor

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
        return Artwork(image: image, tint: averageColor(cg))
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
