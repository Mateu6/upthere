import SwiftUI

// Each ear's content is laid out for the ear's target width and clipped by
// the ear while it animates open, so text never reflows mid-animation.

struct LeftEarContent: View {
    let model: NotchViewModel
    let content: LeftContent

    var body: some View {
        let h = model.geometry.height
        let music = model.nowPlaying
        ZStack {
            if let hud = model.hud, model.showsHUD(on: .left), let snapshot = music.current {
                MusicHUDView(hud: hud, snapshot: snapshot, tint: music.artwork?.tint ?? .white)
                    .transition(.blurReplace)
            } else {
                leftContent(h: h, music: music)
                    .transition(.blurReplace)
                    .id(content)
            }
        }
        .animation(.smooth(duration: 0.28), value: model.showsHUD(on: .left))
    }

    @ViewBuilder private func leftContent(h: CGFloat, music: NowPlayingModel) -> some View {
        ZStack {
            switch content {
            case .none:
                Color.clear
            case .musicArt:
                ArtworkThumb(artwork: music.artwork, size: h - 12, dimmed: music.current?.isPlaying == false)
            case .musicInfo(let expanded):
                if let snapshot = music.current {
                    HStack(spacing: 8) {
                        ArtworkThumb(artwork: music.artwork, size: h - 10, badge: snapshot.parentBundleID ?? snapshot.bundleID)
                            .onTapGesture { music.activatePlayerApp() }
                        TrackText(snapshot: snapshot, showAlbum: expanded)
                        Spacer(minLength: 0)
                    }
                    .padding(.leading, 10)
                    .padding(.trailing, 6)
                }
            case .claudeGlyph:
                ClaudeGlyph(session: model.selectedSession, size: h * 0.46)
            case .claudeDetail(let expanded):
                if let session = model.selectedSession {
                    ClaudeDetail(model: model, session: session, expanded: expanded)
                }
            }
        }
    }
}

struct RightEarContent: View {
    let model: NotchViewModel
    let content: RightContent

    var body: some View {
        let music = model.nowPlaying
        let tint = music.artwork?.tint ?? .white
        ZStack {
            if let hud = model.hud, model.showsHUD(on: .right), let snapshot = music.current {
                MusicHUDView(hud: hud, snapshot: snapshot, tint: tint)
                    .transition(.blurReplace)
            } else {
                rightContent(music: music, tint: tint)
                    .transition(.blurReplace)
                    .id(content)
            }
        }
        .animation(.smooth(duration: 0.28), value: model.showsHUD(on: .right))
    }

    @ViewBuilder private func rightContent(music: NowPlayingModel, tint: NSColor) -> some View {
        let h = model.geometry.height
        ZStack {
            switch content {
            case .none:
                Color.clear
            case .musicBars:
                AudioBarsView(isPlaying: music.current?.isPlaying ?? false, color: tint)
                    .frame(width: 16, height: h * 0.36)
            case .musicCompact:
                HStack(spacing: 7) {
                    ArtworkThumb(artwork: music.artwork, size: h - 12, dimmed: music.current?.isPlaying == false)
                    AudioBarsView(isPlaying: music.current?.isPlaying ?? false, color: tint)
                        .frame(width: 16, height: h * 0.36)
                }
            case .musicControls(let expanded):
                if let snapshot = music.current {
                    HStack(spacing: 6) {
                        TransportControls(model: music, isPlaying: snapshot.isPlaying)
                        if expanded {
                            VStack(alignment: .leading, spacing: 3) {
                                ElapsedLabel(snapshot: snapshot)
                                Scrubber(model: music, snapshot: snapshot, color: tint, interactive: true)
                            }
                        } else {
                            Spacer(minLength: 0)
                        }
                        AudioBarsView(isPlaying: snapshot.isPlaying, color: tint)
                            .frame(width: 16, height: h * 0.36)
                    }
                    .padding(.leading, 6)
                    .padding(.trailing, 12)
                }
            case .musicFull(let expanded):
                if let snapshot = music.current {
                    HStack(spacing: 8) {
                        ArtworkThumb(artwork: music.artwork, size: h - 10, badge: snapshot.parentBundleID ?? snapshot.bundleID)
                            .onTapGesture { music.activatePlayerApp() }
                        VStack(alignment: .leading, spacing: 2) {
                            TrackText(snapshot: snapshot)
                            if expanded {
                                Scrubber(model: music, snapshot: snapshot, color: tint, interactive: true)
                            }
                        }
                        Spacer(minLength: 0)
                        TransportControls(model: music, isPlaying: snapshot.isPlaying, size: 12)
                    }
                    .padding(.leading, 6)
                    .padding(.trailing, 10)
                }
            case .claudeBadge:
                ClaudeBadge(model: model)
            case .claudeTool(let expanded):
                if let session = model.selectedSession {
                    ClaudeToolDetail(session: session, expanded: expanded)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottom) { progressLine(tint: tint) }
    }

    /// A hairline along the ear's bottom edge whenever music is shown collapsed.
    @ViewBuilder private func progressLine(tint: NSColor) -> some View {
        switch content {
        case .musicBars, .musicCompact, .musicControls(expanded: false), .musicFull(expanded: false):
            if let snapshot = model.nowPlaying.current {
                ProgressLineView(snapshot: snapshot, color: tint.withAlphaComponent(0.85))
                    .frame(height: 1.5)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 1)
            }
        default:
            EmptyView()
        }
    }
}

/// Shown in the music ear while scrolling: seek position or volume.
struct MusicHUDView: View {
    let hud: NotchViewModel.HUD
    let snapshot: PlaybackSnapshot
    let tint: NSColor

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 18)
                .contentTransition(.symbolEffect(.replace))
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.16))
                    Capsule().fill(Color(nsColor: tint))
                        .frame(width: max(4, proxy.size.width * fraction))
                }
            }
            .frame(height: 4)
            Text(label)
                .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white.opacity(0.85))
                .fixedSize()
        }
        .padding(.horizontal, 12)
        .animation(.smooth(duration: 0.12), value: fraction)
    }

    private var fraction: CGFloat {
        switch hud {
        case .seek(let t): CGFloat(t / max(snapshot.duration ?? 1, 1))
        case .volume(let v): CGFloat(v)
        }
    }

    private var symbol: String {
        switch hud {
        case .seek: "arrow.left.and.right"
        case .volume(let v): v == 0 ? "speaker.slash.fill" : v < 0.34 ? "speaker.wave.1.fill" : v < 0.67 ? "speaker.wave.2.fill" : "speaker.wave.3.fill"
        }
    }

    private var label: String {
        switch hud {
        case .seek(let t): "\(Theme.time(t)) / \(Theme.time(snapshot.duration ?? 0))"
        case .volume(let v): "\(Int((v * 100).rounded()))%"
        }
    }
}
