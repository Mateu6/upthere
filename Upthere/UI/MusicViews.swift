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
        let frame: Alignment = alignment == .trailing ? .trailing : .leading
        VStack(alignment: alignment, spacing: 0) {
            MarqueeText(text: snapshot.title, font: .system(size: 12, weight: .semibold), alignment: frame)
            MarqueeText(
                text: showAlbum && !snapshot.album.isEmpty ? "\(snapshot.artist) — \(snapshot.album)" : snapshot.artist,
                font: .system(size: 10.5, weight: .medium), color: Theme.secondary, alignment: frame)
        }
    }
}

struct TransportControls: View {
    let model: NowPlayingModel
    let isPlaying: Bool
    var size: CGFloat = 13

    var body: some View {
        HStack(spacing: 2) {
            TransportButton(symbol: "backward.fill", size: size * 0.85, bounce: .backward) { model.send(.previous) }
            TransportButton(symbol: isPlaying ? "pause.fill" : "play.fill", size: size * 1.1) {
                model.send(.togglePlayPause)
            }
            TransportButton(symbol: "forward.fill", size: size * 0.85, bounce: .forward) { model.send(.next) }
        }
    }
}

/// A transport button: a soft disc grows in under the pointer, the glyph
/// sinks while pressed and springs back; skips nudge in their direction and
/// play/pause morph into each other.
private struct TransportButton: View {
    enum Bounce { case backward, forward }

    let symbol: String
    let size: CGFloat
    var bounce: Bounce?
    let action: () -> Void

    @State private var hovering = false
    @State private var taps = 0

    var body: some View {
        Button {
            taps += 1
            action()
        } label: {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(.white)
                .contentTransition(.symbolEffect(.replace.downUp.byLayer))
                .modifier(SkipNudge(bounce: bounce, taps: taps))
                .frame(width: 24, height: 24)
                .contentShape(Circle())
        }
        .buttonStyle(TransportButtonStyle(hovering: hovering))
        .onHover { hovering = $0 }
        .animation(.smooth(duration: 0.25), value: symbol)
    }
}

private struct SkipNudge: ViewModifier {
    let bounce: TransportButton.Bounce?
    let taps: Int

    func body(content: Content) -> some View {
        switch bounce {
        case .backward: content.symbolEffect(.wiggle.backward, options: .speed(1.6), value: taps)
        case .forward: content.symbolEffect(.wiggle.forward, options: .speed(1.6), value: taps)
        case nil: content
        }
    }
}

private struct TransportButtonStyle: ButtonStyle {
    let hovering: Bool

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        configuration.label
            .scaleEffect(pressed ? 0.82 : hovering ? 1.08 : 1)
            .background {
                Circle()
                    .fill(.white.opacity(pressed ? 0.24 : hovering ? 0.14 : 0))
                    .scaleEffect(pressed ? 0.92 : hovering ? 1 : 0.6)
            }
            .animation(pressed ? .spring(duration: 0.12, bounce: 0) : .spring(duration: 0.3, bounce: 0.2), value: pressed)
            .animation(.spring(duration: 0.24, bounce: 0), value: hovering)
    }
}

/// Round icon buttons in the notch: a disc grows in under the pointer and
/// the glyph sinks while pressed.
struct HoverButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HoverButtonBody(configuration: configuration)
    }

    private struct HoverButtonBody: View {
        let configuration: ButtonStyleConfiguration
        @State private var hovering = false

        var body: some View {
            let pressed = configuration.isPressed
            configuration.label
                .scaleEffect(pressed ? 0.86 : hovering ? 1.06 : 1)
                .background {
                    Circle()
                        .fill(.white.opacity(pressed ? 0.22 : hovering ? 0.14 : 0))
                        .scaleEffect(pressed ? 0.92 : hovering ? 1 : 0.6)
                }
                .onHover { hovering = $0 }
                .animation(pressed ? .spring(duration: 0.12, bounce: 0) : .spring(duration: 0.3, bounce: 0.2), value: pressed)
                .animation(.spring(duration: 0.24, bounce: 0), value: hovering)
        }
    }
}

/// Rounded-rectangle hover for rows and text buttons (Up Next chips, the
/// timer field's lists).
struct RowButtonStyle: ButtonStyle {
    var cornerRadius: CGFloat = 6
    var highlighted = false
    /// White in the notch; `.primary` in regular windows.
    var tint: Color = .white

    func makeBody(configuration: Configuration) -> some View {
        RowButtonBody(configuration: configuration, cornerRadius: cornerRadius, highlighted: highlighted, tint: tint)
    }

    private struct RowButtonBody: View {
        let configuration: ButtonStyleConfiguration
        let cornerRadius: CGFloat
        let highlighted: Bool
        let tint: Color
        @State private var hovering = false

        var body: some View {
            let pressed = configuration.isPressed
            configuration.label
                .background {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(tint.opacity(pressed ? 0.16 : hovering || highlighted ? 0.1 : 0))
                }
                .scaleEffect(pressed ? 0.97 : 1)
                .onHover { hovering = $0 }
                .animation(.spring(duration: 0.2, bounce: 0), value: pressed)
                .animation(.spring(duration: 0.24, bounce: 0), value: hovering)
                .animation(.spring(duration: 0.24, bounce: 0), value: highlighted)
        }
    }
}

/// The progress line along the bottom of the music ear, always grabbable.
/// Hovering it for 150 ms grows it upwards (the ear's content moves up to
/// make room); dragging or clicking seeks, previewing the target in the bar.
struct SeekBar: View {
    let model: NotchViewModel
    let snapshot: PlaybackSnapshot
    let color: NSColor
    /// Only when the ear is open (a collapsed ear opens on hover first).
    var interactive: Bool

    var body: some View {
        let active = interactive && model.seekBarActive
        let preview = model.seekPreview
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                if let preview, let duration = snapshot.duration, duration > 0 {
                    Capsule().fill(.white.opacity(0.18))
                    Capsule().fill(Color(nsColor: color))
                        .frame(width: max(4, proxy.size.width * min(1, preview / duration)))
                } else {
                    ProgressLineView(snapshot: snapshot, color: color.withAlphaComponent(0.9))
                }
            }
            .frame(height: active ? 7 : 1.5)
            .frame(maxHeight: .infinity, alignment: .bottom)
            .contentShape(Rectangle())
            .onHover { if interactive { model.seekBarHover($0) } }
            .gesture(interactive ? seekGesture(width: proxy.size.width) : nil)
        }
        .frame(height: interactive ? 10 : 1.5)
        .animation(.spring(duration: 0.28, bounce: 0), value: active)
    }

    private func seekGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard let duration = snapshot.duration else { return }
                model.previewSeek(min(1, max(0, value.location.x / max(width, 1))) * duration)
            }
            .onEnded { value in
                guard let duration = snapshot.duration else { return model.endSeek(at: nil) }
                model.endSeek(at: min(1, max(0, value.location.x / max(width, 1))) * duration)
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

/// Hover feedback for things clicked without a Button (the cover opens the
/// player, Claude's chip opens the chat): a slight lift and brightening.
struct HoverLift: ViewModifier {
    var scale: CGFloat = 1.05
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(hovering ? scale : 1)
            .brightness(hovering ? 0.08 : 0)
            .onHover { hovering = $0 }
            .animation(.spring(duration: 0.24, bounce: 0), value: hovering)
    }
}

extension View {
    func hoverLift(scale: CGFloat = 1.05) -> some View { modifier(HoverLift(scale: scale)) }
}
