import SwiftUI

struct ArtworkThumb: View {
    let artwork: Artwork?
    let size: CGFloat
    var dimmed = false
    /// Bundle ID of the playing app, shown as a small badge.
    var badge: String? = nil

    var body: some View {
        Group {
            if let artwork {
                Image(nsImage: artwork.image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Color.white.opacity(0.12)
                    Image(systemName: "music.note")
                        .font(.system(size: size * 0.45, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.6))
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
        .overlay(alignment: .bottomTrailing) {
            ZStack {
                if let badge, let icon = AppIcons.icon(for: badge) {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: size * 0.46, height: size * 0.46)
                        .shadow(color: .black.opacity(0.6), radius: 1.5)
                        .transition(.scale(scale: 0.4).combined(with: .opacity))
                }
            }
            .offset(x: size * 0.14, y: size * 0.12)
            .animation(.spring(duration: 0.3, bounce: 0), value: badge)
        }
        .opacity(dimmed ? 0.5 : 1)
        .saturation(dimmed ? 0.6 : 1)
        .animation(.easeOut(duration: 0.2), value: artwork)
        .animation(.smooth(duration: 0.45), value: dimmed)
    }
}

/// App icons by bundle ID, looked up once.
enum AppIcons {
    private static var cache: [String: NSImage?] = [:]

    static func icon(for bundleID: String) -> NSImage? {
        if let cached = cache[bundleID] { return cached }
        let icon = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID).map {
            NSWorkspace.shared.icon(forFile: $0.path)
        }
        cache[bundleID] = icon
        return icon
    }
}

struct TrackText: View {
    let snapshot: PlaybackSnapshot
    var showAlbum = false
    var alignment: HorizontalAlignment = .leading

    var body: some View {
        VStack(alignment: alignment, spacing: 0) {
            Text(snapshot.title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
            Text(showAlbum && !snapshot.album.isEmpty ? "\(snapshot.artist) — \(snapshot.album)" : snapshot.artist)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(Theme.secondary)
        }
        .lineLimit(1)
        .truncationMode(.tail)
    }
}

struct TransportControls: View {
    let model: NowPlayingModel
    let isPlaying: Bool
    var size: CGFloat = 13

    var body: some View {
        HStack(spacing: 2) {
            button("backward.fill", size: size * 0.85) { model.send(.previous) }
            button(isPlaying ? "pause.fill" : "play.fill", size: size * 1.1) { model.send(.togglePlayPause) }
                .contentTransition(.symbolEffect(.replace))
            button("forward.fill", size: size * 0.85) { model.send(.next) }
        }
    }

    private func button(_ symbol: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(HoverButtonStyle())
    }
}

struct HoverButtonStyle: ButtonStyle {
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(Circle().fill(.white.opacity(hovering ? 0.14 : 0)))
            .scaleEffect(configuration.isPressed ? 0.88 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .onHover { hovering = $0 }
    }
}

/// The progress line along the bottom of the music ear, always grabbable:
/// it thickens under the pointer, and dragging (or clicking) seeks, showing
/// the target time in the ear while you drag.
struct SeekBar: View {
    let model: NotchViewModel
    let snapshot: PlaybackSnapshot
    let color: NSColor
    let side: NotchSide
    /// Only when the ear is open (a collapsed ear opens on hover first).
    var interactive: Bool

    @State private var hovering = false
    @State private var dragFraction: Double?

    var body: some View {
        let active = interactive && (hovering || dragFraction != nil)
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                if let dragFraction {
                    Capsule().fill(.white.opacity(0.18))
                    Capsule().fill(Color(nsColor: color))
                        .frame(width: max(4, proxy.size.width * dragFraction))
                } else {
                    ProgressLineView(snapshot: snapshot, color: color.withAlphaComponent(0.9))
                }
            }
            .frame(height: active ? 5 : 1.5)
            .frame(maxHeight: .infinity, alignment: .bottom)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .gesture(interactive ? seekGesture(width: proxy.size.width) : nil)
        }
        .frame(height: interactive ? 12 : 1.5)
        .animation(.spring(duration: 0.22, bounce: 0), value: active)
    }

    private func seekGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let fraction = min(1, max(0, value.location.x / max(width, 1)))
                dragFraction = fraction
                if let duration = snapshot.duration { model.previewSeek(fraction * duration, side: side) }
            }
            .onEnded { value in
                let fraction = min(1, max(0, value.location.x / max(width, 1)))
                if let duration = snapshot.duration { model.nowPlaying.send(.seek(fraction * duration)) }
                model.previewSeek(nil, side: side)
                dragFraction = nil
            }
    }
}

struct ElapsedLabel: View {
    let snapshot: PlaybackSnapshot

    var body: some View {
        // Ticks only while visible (expanded), and only once per second.
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Text("\(Theme.time(snapshot.position(at: context.date))) / \(Theme.time(snapshot.duration ?? 0))")
                .font(.system(size: 9.5, weight: .medium).monospacedDigit())
                .foregroundStyle(Theme.secondary)
        }
    }
}
