import SwiftUI

/// Lets the user scroll a rolling line sideways (fed by the notch's scroll
/// handler). While they scroll, the line follows them; about a second after
/// they stop, it keeps rolling from wherever they left it.
@Observable
final class MarqueeScrubber {
    /// Bumped on every scroll event.
    private(set) var tick = 0
    private(set) var isScrubbing = false
    @ObservationIgnored private var pending: CGFloat = 0
    @ObservationIgnored private var endTask: Task<Void, Never>?

    func scrub(by delta: CGFloat) {
        pending += delta
        tick &+= 1
        if !isScrubbing { isScrubbing = true }
        endTask?.cancel()
        endTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.1))
            guard !Task.isCancelled else { return }
            self?.isScrubbing = false
        }
    }

    func take() -> CGFloat {
        defer { pending = 0 }
        return pending
    }
}

/// One line of text that, when it doesn't fit, scrolls to reveal the rest
/// (pause, glide, pause, back) instead of truncating — without changing
/// its own size. Animates only while it overflows and is on screen.
/// With a `scrubber`, the user can scroll it sideways too.
struct MarqueeText: View {
    let text: String
    let font: Font
    var color: Color = .white
    var alignment: Alignment = .leading
    /// Take only the text's own width (when it fits) instead of all that's
    /// offered, so things beside it stay close.
    var hugs = false
    var scrubber: MarqueeScrubber? = nil

    @State private var textWidth: CGFloat = 0
    @State private var offset: CGFloat = 0
    /// The running roll, so its on-screen position can be worked out when
    /// the user takes over mid-glide.
    @State private var glide: Glide?
    @State private var rolledText: String?

    private struct Glide {
        var from: CGFloat
        var to: CGFloat
        var start: Date
        var duration: Double
        var eased: Bool
    }

    private static let speed: CGFloat = 32  // points per second
    private static let fade: CGFloat = 8

    var body: some View {
        let scrubbing = scrubber?.isScrubbing ?? false
        // An invisible copy gives the line its height and flexible width.
        Text(text)
            .font(font)
            .lineLimit(1)
            .opacity(0)
            .frame(maxWidth: hugs ? nil : .infinity, alignment: alignment)
            .overlay {
                GeometryReader { proxy in
                    let overflow = max(0, textWidth - proxy.size.width)
                    Text(text)
                        .font(font)
                        .foregroundStyle(color)
                        .lineLimit(1)
                        .fixedSize()
                        .background {
                            GeometryReader { measured in
                                Color.clear
                                    .onAppear { textWidth = measured.size.width }
                                    .onChange(of: measured.size.width) { _, width in textWidth = width }
                            }
                        }
                        .offset(x: -offset)
                        .frame(width: proxy.size.width, alignment: overflow > 0 ? .leading : alignment)
                        .mask(edgeFade(overflowing: overflow > 0))
                        .task(id: "\(text)|\(Int(overflow))|\(scrubbing)") {
                            guard !scrubbing else { return }
                            await roll(overflow)
                        }
                        .onChange(of: scrubber?.tick ?? 0) { applyScrub(overflow) }
                }
            }
    }

    private func edgeFade(overflowing: Bool) -> some View {
        GeometryReader { proxy in
            let fade = min(0.2, Self.fade / max(proxy.size.width, 1))
            LinearGradient(
                stops: [
                    .init(color: overflowing && offset > 0 ? .clear : .white, location: 0),
                    .init(color: .white, location: fade),
                    .init(color: .white, location: 1 - fade),
                    .init(color: overflowing ? .clear : .white, location: 1),
                ], startPoint: .leading, endPoint: .trailing)
        }
    }

    /// Where the text is on screen right now (mid-glide included).
    private func presentedOffset(at date: Date = .now) -> CGFloat {
        guard let glide else { return offset }
        let p = min(1, max(0, date.timeIntervalSince(glide.start) / max(glide.duration, 0.001)))
        let t = glide.eased ? p * p * (3 - 2 * p) : p
        return glide.from + (glide.to - glide.from) * CGFloat(t)
    }

    private func move(to target: CGFloat, duration: Double, eased: Bool) {
        glide = Glide(from: presentedOffset(), to: target, start: .now, duration: duration, eased: eased)
        withAnimation(eased ? .easeInOut(duration: duration) : .linear(duration: duration)) { offset = target }
    }

    /// Stops a running glide where it is on screen.
    private func freeze() {
        let current = presentedOffset()
        glide = nil
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { offset = current }
    }

    private func applyScrub(_ overflow: CGFloat) {
        let delta = scrubber?.take() ?? 0
        guard overflow > 1, delta != 0 else { return }
        if glide != nil { freeze() }
        let travel = overflow + Self.fade
        withAnimation(.interactiveSpring(response: 0.3, dampingFraction: 1)) {
            offset = min(travel, max(0, offset + delta))
        }
    }

    /// Pause, glide to the end, pause, glide back; repeat. Picks up from the
    /// current position (e.g. where the user left it).
    private func roll(_ overflow: CGFloat) async {
        if rolledText != text {
            rolledText = text
            glide = nil
            offset = 0
        }
        guard overflow > 1 else {
            if offset != 0 { move(to: 0, duration: 0.3, eased: true) }
            return
        }
        let travel = overflow + Self.fade
        var resuming = presentedOffset() > 0.5
        while !Task.isCancelled {
            let from = min(presentedOffset(), travel)
            if from < travel - 0.5 {
                try? await Task.sleep(for: .seconds(resuming ? 0.6 : 1.6))
                guard !Task.isCancelled else { return }
                let duration = Double((travel - from) / Self.speed)
                move(to: travel, duration: duration, eased: false)
                try? await Task.sleep(for: .seconds(duration + 1.4))
            } else {
                try? await Task.sleep(for: .seconds(1.4))
            }
            guard !Task.isCancelled else { return }
            move(to: 0, duration: 0.45, eased: true)
            try? await Task.sleep(for: .seconds(0.45))
            resuming = false
        }
    }
}
