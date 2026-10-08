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
                    .hoverLift(scale: 1.02)
                    .onTapGesture { model.openSettings() }
            case .error(let message):
                hint(message, systemImage: "exclamationmark.triangle")
            case .unsupported:
                hint("Up Next isn't available for this player", systemImage: "list.bullet")
            case .loading where queue.items.isEmpty:
                ProgressView().controlSize(.mini)
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
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.white)
                    Text(item.artist)
                        .font(.system(size: 9.5, weight: .medium))
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
            MarqueeText(text: text, font: .system(size: 10, weight: .medium), color: Theme.secondary)
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
                Color.white.opacity(0.1)
                Image(systemName: "music.note").font(.system(size: size * 0.45)).foregroundStyle(.white.opacity(0.5))
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
