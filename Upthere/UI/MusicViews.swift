import SwiftUI

struct ArtworkThumb: View {
    let artwork: Artwork?
    let size: CGFloat
    var dimmed = false

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
        .opacity(dimmed ? 0.55 : 1)
        .animation(.easeOut(duration: 0.2), value: artwork)
    }
}

struct TrackText: View {
    let snapshot: PlaybackSnapshot
    var showAlbum = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
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

/// Progress line that becomes a seek bar when `interactive`.
struct Scrubber: View {
    let model: NowPlayingModel
    let snapshot: PlaybackSnapshot
    let color: NSColor
    var interactive = false
    @State private var dragFraction: Double?

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                if let dragFraction {
                    Capsule().fill(.white.opacity(0.16))
                    Capsule().fill(Color(nsColor: color))
                        .frame(width: proxy.size.width * dragFraction)
                } else {
                    ProgressLineView(snapshot: snapshot, color: color)
                }
            }
            .frame(height: interactive ? 3 : 2)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(interactive ? seekGesture(width: proxy.size.width) : nil)
        }
        .frame(height: interactive ? 10 : 2)
    }

    private func seekGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { dragFraction = min(1, max(0, $0.location.x / max(width, 1))) }
            .onEnded { value in
                let fraction = min(1, max(0, value.location.x / max(width, 1)))
                if let duration = snapshot.duration { model.send(.seek(fraction * duration)) }
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
