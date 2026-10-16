import ImageIO
import SwiftUI

/// Upcoming songs as a sideways-scrolling strip of cover + title chips.
struct QueueStrip: View {
    let model: NotchViewModel

    var body: some View {
        let queue = model.queue
        let h = model.geometry.height
        Group {
            switch queue.status {
            case .needsSpotifyLogin:
                hint("Connect Spotify in Settings to see Up Next", systemImage: "link")
                    .liftButton(scale: 1.02) { model.openSettings() }
            case .error(let message):
                // A way forward, not a dead end.
                HStack(spacing: 4) {
                    hint(message, systemImage: "exclamationmark.triangle")
                    Button {
                        queue.refresh(for: model.nowPlaying.current, force: true)
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Theme.Ink.icon)
                            .frame(width: 20, height: 20)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(HoverButtonStyle())
                    .help("Try again")
                }
            case .unsupported:
                hint("Up Next isn't available for this player", systemImage: "list.bullet")
            case .loading where queue.items.isEmpty:
                QueueSkeleton(size: h - 14)
            default:
                if queue.items.isEmpty {
                    hint("Nothing up next", systemImage: "list.bullet")
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(spacing: 6) {
                            ForEach(queue.items) { item in
                                chip(item, size: h - 14)
                            }
                        }
                        .padding(.trailing, 6)
                        // The gaps between songs count too, so a scroll
                        // anywhere over the list moves it.
                        .frame(maxHeight: .infinity)
                        .contentShape(Rectangle())
                    }
                    .scrollClipDisabled(false)
                    .mask(
                        LinearGradient(
                            stops: [.init(color: .white, location: 0.85), .init(color: .clear, location: 1)],
                            startPoint: .leading, endPoint: .trailing))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.smooth(duration: 0.25), value: queue.items)
    }

    private func chip(_ item: QueueItem, size: CGFloat) -> some View {
        Button {
            if let player = model.nowPlaying.current?.bundleID { model.queue.play(item, player: player) }
        } label: {
            HStack(spacing: 6) {
                RemoteThumb(url: item.artworkURL, size: size)
                VStack(alignment: .leading, spacing: 0) {
                    Text(item.title)
                        .font(Theme.TextStyle.label.font)
                        .foregroundStyle(.white)
                    Text(item.artist)
                        .font(Theme.TextStyle.caption.font)
                        .foregroundStyle(Theme.secondary)
                }
                .lineLimit(1)
                .frame(maxWidth: 96, alignment: .leading)
            }
            .padding(.vertical, 2)
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(ChipButtonStyle())
        .help("\(item.title) — \(item.artist)")
    }

    private func hint(_ text: String, systemImage: String) -> some View {
        // Rolls instead of truncating when it doesn't fit.
        HStack(spacing: 5) {
            Image(systemName: systemImage).font(.system(size: 10, weight: .medium)).foregroundStyle(Theme.secondary)
            MarqueeText(text: text, font: Theme.TextStyle.body.font, color: Theme.secondary)
        }
    }
}

/// Placeholder chips while Up Next loads. The list's shape is known, so a
/// skeleton rather than a spinner, and only after 300 ms so a fast load
/// shows nothing at all.
private struct QueueSkeleton: View {
    let size: CGFloat
    @State private var shown = false

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<3, id: \.self) { _ in
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: size * 0.2, style: .continuous).fill(Theme.Ink.placeholder)
                        .frame(width: size, height: size)
                    VStack(alignment: .leading, spacing: 4) {
                        Capsule().fill(Theme.Ink.placeholder).frame(width: 64, height: 6)
                        Capsule().fill(Theme.Ink.faint).frame(width: 44, height: 5)
                    }
                }
                .padding(.vertical, 2)
                .padding(.horizontal, 4)
            }
        }
        .opacity(shown ? 1 : 0)
        .animation(.easeOut(duration: 0.2), value: shown)
        .task {
            try? await Task.sleep(for: .milliseconds(300))
            shown = true
        }
    }
}

struct ChipButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        RowButtonStyle().makeBody(configuration: configuration)
    }
}

/// A small cover loaded from a URL, downsampled and cached.
struct RemoteThumb: View {
    let url: URL?
    let size: CGFloat
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill).transition(.opacity)
            } else {
                Theme.Ink.placeholder
                Image(systemName: "music.note").font(.system(size: size * 0.45)).foregroundStyle(Theme.Ink.glyph)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.2, style: .continuous))
        .task(id: url) {
            guard let url else { return }
            image = await ThumbnailCache.shared.image(for: url, pixels: size * 2)
        }
    }
}

/// Small LRU of downsampled cover thumbnails.
final class ThumbnailCache {
    static let shared = ThumbnailCache()
    private var cache: [URL: NSImage] = [:]
    private var order: [URL] = []

    func image(for url: URL, pixels: CGFloat) async -> NSImage? {
        if let cached = cache[url] { return cached }
        guard let data = try? await URLSession.shared.data(from: url).0 else { return nil }
        let image = await Task.detached(priority: .utility) { Self.decode(data, pixels: pixels) }.value
        if let image {
            cache[url] = image
            order.append(url)
            if order.count > 60 { cache.removeValue(forKey: order.removeFirst()) }
        }
        return image
    }

    nonisolated private static func decode(_ data: Data, pixels: CGFloat) -> NSImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: pixels,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width / 2, height: cg.height / 2))
    }
}
