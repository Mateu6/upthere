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
            switch content {
            case .none:
                Color.clear
            case .musicArt:
                ArtworkThumb(artwork: music.artwork, size: h - 12, dimmed: music.current?.isPlaying == false)
            case .musicInfo(let expanded):
                if let snapshot = music.current {
                    HStack(spacing: 8) {
                        ArtworkThumb(artwork: music.artwork, size: h - 10)
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
        .transition(.opacity.animation(.easeOut(duration: 0.15)))
        .id(content)
    }
}

struct RightEarContent: View {
    let model: NotchViewModel
    let content: RightContent

    var body: some View {
        let h = model.geometry.height
        let music = model.nowPlaying
        let tint = music.artwork?.tint ?? .white
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
                        ArtworkThumb(artwork: music.artwork, size: h - 10)
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
        .transition(.opacity.animation(.easeOut(duration: 0.15)))
        .id(content)
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
