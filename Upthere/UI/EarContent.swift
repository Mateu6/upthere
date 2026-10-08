import SwiftUI

// Layout rule: each ear's anchor element sits right next to the notch, in
// the same spot in every state, and never moves:
//   left ear:  cover (music) or Claude's spark
//   right ear: sound bars (music only) or the cover (when Claude has the left ear)
// Everything else extends outwards from it, laid out at the ear's target
// width and revealed by the mask as the ear opens. Nothing animates geometry,
// so nothing can jump or drift against the mask.

struct LeftEarContent: View {
    let model: NotchViewModel
    let content: LeftContent

    private enum Anchor: Equatable { case art, spark }

    private var anchor: Anchor? {
        switch content {
        case .musicArt, .musicInfo, .queue: .art
        case .claudeGlyph, .claudeDetail, .claudePiece: .spark
        case .timer, .timerStrip, .none: nil
        }
    }

    var body: some View {
        let h = model.geometry.height
        let music = model.nowPlaying
        ZStack(alignment: .trailing) {
            ZStack {
                if let hud = model.hud, model.showsHUD(on: .left), let snapshot = music.current {
                    MusicHUDView(hud: hud, snapshot: snapshot, tint: music.artwork?.tint ?? .white, trailing: h + 4)
                        .transition(.blurReplace)
                } else {
                    details(h: h, music: music)
                        // Laid out at the ear's width, springing with the
                        // mask when it changes, so nothing snaps.
                        .frame(width: model.leftWidth, alignment: .trailing)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .animation(.spring(duration: Theme.earDuration, bounce: 0), value: model.leftWidth)
                        .transition(.blurReplace)
                        .id(content.identity)
                }
            }
            .animation(.smooth(duration: 0.28), value: model.showsHUD(on: .left))
            .animation(.smooth(duration: 0.28), value: content)

            anchorView(h: h, music: music)
                .frame(width: h + 4, height: h)
        }
    }

    @ViewBuilder private func anchorView(h: CGFloat, music: NowPlayingModel) -> some View {
        ZStack {
            switch anchor {
            case .art:
                ArtworkThumb(
                    artwork: music.artwork, size: h - 10, dimmed: music.current?.isPlaying == false,
                    badge: content == .musicArt ? nil : music.current.map { $0.parentBundleID ?? $0.bundleID }
                )
                .hoverLift(scale: 1.08)
                .onTapGesture { music.activatePlayerApp() }
                .transition(.blurReplace)
            case .spark:
                ClaudeGlyph(session: model.selectedSession, size: h * 0.46, ring: model.usageRing)
                    .transition(.blurReplace)

            case nil:
                EmptyView()
            }
        }
        .animation(.smooth(duration: 0.28), value: anchor)
    }

    /// Everything beyond the anchor, reading outwards from the notch.
    @ViewBuilder private func details(h: CGFloat, music: NowPlayingModel) -> some View {
        ZStack {
            switch content {
            case .none, .musicArt, .claudeGlyph:
                Color.clear
            case .musicInfo(let expanded):
                if let snapshot = music.current {
                    HStack(spacing: 0) {
                        Spacer(minLength: 0)
                        TrackText(snapshot: snapshot, showAlbum: expanded, alignment: .trailing)
                    }
                    .padding(.leading, 12)
                    .padding(.trailing, h + 4)
                }
            case .claudeDetail(let expanded):
                if let session = model.selectedSession {
                    ClaudeDetail(model: model, session: session, expanded: expanded)
                        .padding(.leading, 8)
                        .padding(.trailing, h + 4)
                } else {
                    UsageSummary(model: model)
                        .padding(.leading, 8)
                        .padding(.trailing, h + 4)
                }
            case .queue:
                QueueStrip(model: model)
                    .padding(.leading, 10)
                    .padding(.trailing, h + 2)
            case .timer:
                TimerCollapsed(model: model)
                    .padding(.leading, 8)
                    .padding(.trailing, 6)
            case .timerStrip:
                TimerStrip(model: model, stripWidth: model.leftWidth)
            case .claudePiece(let part):
                // [timers | Claude] with Claude fixed next to the notch.
                let piece = model.claudePieceWidth - (h + 4)
                HStack(spacing: 0) {
                    switch part {
                    case .none:
                        Spacer(minLength: 0)
                    case .collapsed:
                        TimerCollapsed(model: model, showsClaude: false)
                            .padding(.leading, 8)
                            .padding(.trailing, 8)
                            .transition(.blurReplace)
                        PieceDivider()
                    case .strip:
                        TimerStrip(
                            model: model, stripWidth: max(0, model.leftWidth - model.claudePieceWidth), showsClaude: false
                        )
                        .transition(.blurReplace)
                        PieceDivider()
                    }
                    if let session = model.selectedSession {
                        ClaudePiece(model: model, session: session).frame(width: piece, alignment: .trailing)
                    } else {
                        Color.clear.frame(width: piece)
                    }
                }
                .padding(.trailing, h + 4)
                // Grows and shrinks with the ear's own spring.
                .animation(.spring(duration: Theme.earDuration, bounce: 0), value: piece)
            }
        }
    }
}

struct RightEarContent: View {
    let model: NotchViewModel
    let content: RightContent

    private enum Anchor: Equatable { case bars, art }

    private var anchor: Anchor? {
        switch content {
        case .musicBars, .musicControls: .bars
        case .musicCompact, .musicFull, .musicWithTimers: .art
        default: nil
        }
    }

    var body: some View {
        let music = model.nowPlaying
        let tint = music.artwork?.tint ?? .white
        let h = model.geometry.height
        ZStack(alignment: .leading) {
            ZStack {
                if let hud = model.hud, model.showsHUD(on: .right), let snapshot = music.current {
                    MusicHUDView(hud: hud, snapshot: snapshot, tint: tint, leading: h + 4)
                        .frame(width: content.isMusicWithTimers ? model.musicPieceWidth : nil)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .transition(.blurReplace)
                } else {
                    details(music: music, tint: tint)
                        .frame(width: model.rightWidth, alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .animation(.spring(duration: Theme.earDuration, bounce: 0), value: model.rightWidth)
                        .transition(.blurReplace)
                        .id(content.identity)
                }
            }
            .animation(.smooth(duration: 0.28), value: model.showsHUD(on: .right))
            .animation(.smooth(duration: 0.28), value: content)

            anchorView(h: h, music: music, tint: tint)
                .frame(width: h + 4, height: h)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Make room for the grown seek bar.
        .offset(y: model.seekBarActive ? -4 : 0)
        .animation(.spring(duration: 0.28, bounce: 0), value: model.seekBarActive)
        .overlay(alignment: .bottom) { progressLine(tint: tint) }
    }

    @ViewBuilder private func anchorView(h: CGFloat, music: NowPlayingModel, tint: NSColor) -> some View {
        ZStack {
            switch anchor {
            case .bars:
                AudioBarsView(
                    isPlaying: music.current?.isPlaying ?? false, color: tint, live: model.prefs.liveVisualizer
                )
                .frame(width: 16, height: h * 0.36)
                .transition(.blurReplace)
            case .art:
                ArtworkThumb(
                    artwork: music.artwork, size: h - 10, dimmed: music.current?.isPlaying == false,
                    badge: content == .musicCompact ? nil : music.current.map { $0.parentBundleID ?? $0.bundleID }
                )
                .hoverLift(scale: 1.08)
                .onTapGesture { music.activatePlayerApp() }
                .transition(.blurReplace)
            case nil:
                EmptyView()
            }
        }
        .animation(.smooth(duration: 0.28), value: anchor)
    }

    /// Everything beyond the anchor, reading outwards from the notch.
    @ViewBuilder private func details(music: NowPlayingModel, tint: NSColor) -> some View {
        let h = model.geometry.height
        ZStack {
            switch content {
            case .none, .musicBars:
                Color.clear
            case .musicCompact:
                // Cover is the anchor; the bars sit just outside it.
                HStack(spacing: 0) {
                    AudioBarsView(
                        isPlaying: music.current?.isPlaying ?? false, color: tint, live: model.prefs.liveVisualizer
                    )
                    .frame(width: 16, height: h * 0.36)
                    Spacer(minLength: 0)
                }
                .padding(.leading, h + 2)
            case .musicControls:
                if let snapshot = music.current {
                    HStack(spacing: 8) {
                        TrackText(snapshot: snapshot)
                        Spacer(minLength: 0)
                        TransportControls(model: music, isPlaying: snapshot.isPlaying, size: 12)
                    }
                    .padding(.leading, h + 4)
                    .padding(.trailing, 10)
                }
            case .musicFull:
                if let snapshot = music.current {
                    HStack(spacing: 8) {
                        TrackText(snapshot: snapshot)
                        Spacer(minLength: 0)
                        TransportControls(model: music, isPlaying: snapshot.isPlaying, size: 12)
                    }
                    .padding(.leading, h + 4)
                    .padding(.trailing, 10)
                }
            case .musicWithTimers(let strip):
                // [music | timers] with music fixed next to the notch.
                HStack(spacing: 0) {
                    if let snapshot = music.current {
                        HStack(spacing: 8) {
                            TrackText(snapshot: snapshot)
                            TransportControls(model: music, isPlaying: snapshot.isPlaying, size: 12)
                        }
                        .padding(.trailing, 8)
                        .frame(width: model.musicPieceWidth - (h + 4), alignment: .leading)
                    }
                    PieceDivider()
                    if strip {
                        TimerStrip(
                            model: model, stripWidth: max(0, model.rightWidth - model.musicPieceWidth),
                            showsClaude: false, mirrored: true
                        )
                        .transition(.blurReplace)
                    } else {
                        TimerCollapsed(model: model, showsClaude: false, mirrored: true)
                            .padding(.leading, 8)
                            .padding(.trailing, 8)
                            .transition(.blurReplace)
                    }
                }
                .padding(.leading, h + 4)
            case .claudeBadge:
                ClaudeBadge(model: model)
            case .claudeTool(let expanded):
                if let session = model.selectedSession {
                    ClaudeToolDetail(session: session, expanded: expanded, chips: model.usageChips(for: session))
                }
            }
        }
    }

    /// The seek bar along the ear's bottom edge whenever it shows music.
    @ViewBuilder private func progressLine(tint: NSColor) -> some View {
        switch content {
        case .musicBars, .musicCompact, .musicControls, .musicFull, .musicWithTimers:
            if let snapshot = model.nowPlaying.current {
                SeekBar(
                    model: model, snapshot: snapshot, color: tint, interactive: model.isOpen(.right)
                )
                .padding(.horizontal, 8)
                .padding(.bottom, 1)
                // Only under the music when the timers share the ear.
                .frame(width: content.isMusicWithTimers ? model.musicPieceWidth : nil)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        default:
            EmptyView()
        }
    }
}

/// Shown in the music ear while scrolling for volume.
struct MusicHUDView: View {
    let hud: NotchViewModel.HUD
    let snapshot: PlaybackSnapshot
    let tint: NSColor
    /// Room left for the anchor next to the notch.
    var leading: CGFloat = 12
    var trailing: CGFloat = 12

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
        .padding(.leading, leading)
        .padding(.trailing, trailing)
        .animation(.smooth(duration: 0.12), value: fraction)
    }

    private var fraction: CGFloat {
        switch hud {
        case .volume(let v): CGFloat(v)
        }
    }

    private var symbol: String {
        switch hud {
        case .volume(let v):
            v == 0 ? "speaker.slash.fill" : v < 0.34 ? "speaker.wave.1.fill" : v < 0.67 ? "speaker.wave.2.fill" : "speaker.wave.3.fill"
        }
    }

    private var label: String {
        switch hud {
        case .volume(let v): "\(Int((v * 100).rounded()))%"
        }
    }
}

private extension RightContent {
    var isMusicWithTimers: Bool { if case .musicWithTimers = self { true } else { false } }

    /// What a content swap cross-fades between: the shared-ear layouts keep
    /// one identity, so only their timers part changes, never the music.
    var identity: String {
        switch self {
        case .musicWithTimers: "musicWithTimers"
        default: "\(self)"
        }
    }
}

private extension LeftContent {
    var identity: String {
        switch self {
        case .claudePiece: "claudePiece"
        default: "\(self)"
        }
    }
}
