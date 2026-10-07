import AppKit
import QuartzCore
import SwiftUI

// Continuous animations live on the render server as Core Animation layer
// animations, so they cost the app no CPU per frame (unlike SwiftUI
// repeatForever animations, which tick in-process).
//
// Ambient loops are capped below the display's native rate: they look the
// same at 60 Hz (or 30 for the slow progress line) and leave the GPU idle
// more often. Open/close springs run at the native rate (see EarWindow).

extension CAAnimation {
    static let ambientFrameRate = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
    static let slowFrameRate = CAFrameRateRange(minimum: 8, maximum: 30, preferred: 30)
}

// MARK: - Audio bars

struct AudioBarsView: NSViewRepresentable {
    var isPlaying: Bool
    var color: NSColor
    /// Drive the bars from the live audio levels (AudioVisualizer).
    var live = false

    func makeNSView(context: Context) -> AudioBarsNSView { AudioBarsNSView() }
    func updateNSView(_ view: AudioBarsNSView, context: Context) {
        view.update(playing: isPlaying, color: color, live: live)
    }
}

final class AudioBarsNSView: NSView {
    private let bars: [CALayer] = (0..<4).map { _ in CALayer() }
    private var playing = false
    private var bouncing = false
    private var live = false
    private var link: CADisplayLink?
    private var shown = SIMD4<Float>(repeating: 0)
    private static let durations: [CFTimeInterval] = [0.42, 0.57, 0.36, 0.5]
    private static let phases: [CFTimeInterval] = [0, 0.21, 0.09, 0.33]
    private static let rest: CGFloat = 0.28

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        for bar in bars {
            bar.anchorPoint = CGPoint(x: 0.5, y: 0)
            bar.cornerRadius = 1
            bar.transform = CATransform3DMakeScale(1, Self.rest, 1)
            layer?.addSublayer(bar)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let barWidth: CGFloat = 2.5
        let gap: CGFloat = 2
        let total = CGFloat(bars.count) * barWidth + CGFloat(bars.count - 1) * gap
        var x = (bounds.width - total) / 2
        for bar in bars {
            bar.bounds = CGRect(x: 0, y: 0, width: barWidth, height: bounds.height)
            bar.position = CGPoint(x: x + barWidth / 2, y: 0)
            x += barWidth + gap
        }
        CATransaction.commit()
    }

    func update(playing: Bool, color: NSColor, live: Bool = false) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for bar in bars { bar.backgroundColor = color.cgColor }
        CATransaction.commit()
        guard playing != self.playing || live != self.live else { return }
        self.playing = playing
        self.live = live
        updateDriver()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateDriver()
    }

    /// Live: a display link reads the audio levels (falling back to the
    /// canned bounce whenever no audio data arrives). Otherwise a render-
    /// server animation, or rest when paused.
    private func updateDriver() {
        if playing && live && window != nil {
            if link == nil {
                let link = displayLink(target: self, selector: #selector(tick(_:)))
                link.preferredFrameRateRange = CAAnimation.ambientFrameRate
                link.add(to: .main, forMode: .common)
                self.link = link
            }
        } else {
            link?.invalidate()
            link = nil
        }
        if !playing {
            bouncing = false
            rest()
        } else {
            setBouncing(!(live && window != nil))
        }
    }

    @objc private func tick(_ link: CADisplayLink) {
        let (levels, age) = AudioVisualizer.shared.store.read()
        guard age < 0.4 else {
            setBouncing(true)  // no audio data: canned animation
            return
        }
        setBouncing(false)
        // Quick rise, slower fall, like a VU meter.
        for i in 0..<4 {
            let target = levels[i]
            shown[i] += (target - shown[i]) * (target > shown[i] ? 0.55 : 0.18)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (i, bar) in bars.enumerated() {
            bar.transform = CATransform3DMakeScale(1, Self.rest + (1 - Self.rest) * CGFloat(shown[i]), 1)
        }
        CATransaction.commit()
    }

    /// Paused: each bar glides down from wherever it is to rest.
    private func rest() {
        shown = .zero
        for bar in bars {
            let current = (bar.presentation()?.value(forKeyPath: "transform.scale.y") as? CGFloat) ?? Self.rest
            bar.removeAnimation(forKey: "bounce")
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            bar.transform = CATransform3DMakeScale(1, Self.rest, 1)
            CATransaction.commit()
            guard abs(current - Self.rest) > 0.01 else { continue }
            let settle = CABasicAnimation(keyPath: "transform.scale.y")
            settle.fromValue = current
            settle.toValue = Self.rest
            settle.duration = 0.45
            settle.timingFunction = CAMediaTimingFunction(name: .easeOut)
            bar.add(settle, forKey: "settle")
        }
    }

    private func setBouncing(_ on: Bool) {
        guard on != bouncing else { return }
        bouncing = on
        guard on else {
            if playing { for bar in bars { bar.removeAnimation(forKey: "bounce") } }
            return  // when pausing, rest() takes the bars down smoothly
        }
        let now = CACurrentMediaTime()
        for (index, bar) in bars.enumerated() {
            bar.removeAnimation(forKey: "settle")
            let animation = CABasicAnimation(keyPath: "transform.scale.y")
            animation.fromValue = Self.rest
            animation.toValue = 1.0
            animation.duration = Self.durations[index]
            animation.autoreverses = true
            animation.repeatCount = .infinity
            animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            // Start from rest, staggered, instead of jumping mid-bounce.
            animation.beginTime = now + Self.phases[index] * 0.5
            animation.fillMode = .backwards
            animation.preferredFrameRateRange = CAAnimation.ambientFrameRate
            bar.add(animation, forKey: "bounce")
        }
    }
}

// MARK: - Progress line

/// A thin progress bar that advances on its own via a linear CA animation
/// from the current position to the end of the track.
struct ProgressLineView: NSViewRepresentable {
    var snapshot: PlaybackSnapshot?
    var color: NSColor

    func makeNSView(context: Context) -> ProgressLineNSView { ProgressLineNSView() }
    func updateNSView(_ view: ProgressLineNSView, context: Context) { view.update(snapshot: snapshot, color: color) }
}

final class ProgressLineNSView: NSView {
    private let track = CALayer()
    private let fill = CALayer()
    private var snapshot: PlaybackSnapshot?
    private var lastSize: CGSize = .zero

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        track.backgroundColor = NSColor.white.withAlphaComponent(0.16).cgColor
        fill.anchorPoint = CGPoint(x: 0, y: 0.5)
        layer?.addSublayer(track)
        layer?.addSublayer(fill)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        // Height changes too: the seek bar grows under the pointer.
        if bounds.size != lastSize {
            lastSize = bounds.size
            restart()
        }
    }

    func update(snapshot: PlaybackSnapshot?, color: NSColor) {
        fill.backgroundColor = color.cgColor
        guard snapshot != self.snapshot else { return }
        self.snapshot = snapshot
        restart()
    }

    private func restart() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let h = bounds.height
        track.frame = bounds
        track.cornerRadius = h / 2
        fill.cornerRadius = h / 2
        fill.removeAnimation(forKey: "progress")

        let width = bounds.width
        let fraction = snapshot?.progress() ?? 0
        fill.bounds = CGRect(x: 0, y: 0, width: width * fraction, height: h)
        fill.position = CGPoint(x: 0, y: h / 2)

        if let snapshot, snapshot.isPlaying, let duration = snapshot.duration, duration > 0, width > 0 {
            let remaining = (duration - snapshot.position()) / max(snapshot.rate, 0.01)
            if remaining > 0 {
                let animation = CABasicAnimation(keyPath: "bounds.size.width")
                animation.fromValue = width * fraction
                animation.toValue = width
                animation.duration = remaining
                animation.timingFunction = CAMediaTimingFunction(name: .linear)
                animation.fillMode = .forwards
                animation.isRemovedOnCompletion = false
                animation.preferredFrameRateRange = CAAnimation.slowFrameRate
                fill.add(animation, forKey: "progress")
            }
        }
        CATransaction.commit()
    }
}

// MARK: - Claude spark

/// Claude Code's asterisk-like spinner: rotates while working, pulses while
/// waiting for the user.
struct ClaudeSparkView: NSViewRepresentable {
    enum Style: Equatable { case working, waiting, idle }
    var style: Style
    var color: NSColor

    func makeNSView(context: Context) -> ClaudeSparkNSView { ClaudeSparkNSView() }
    func updateNSView(_ view: ClaudeSparkNSView, context: Context) { view.update(style: style, color: color) }
}

final class ClaudeSparkNSView: NSView {
    private let shape = CAShapeLayer()
    private var style: ClaudeSparkView.Style?
    private var lastSize: CGSize = .zero

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        shape.fillColor = nil
        shape.lineCap = .round
        layer?.addSublayer(shape)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        guard bounds.size != lastSize else { return }
        lastSize = bounds.size
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shape.bounds = bounds
        shape.position = CGPoint(x: bounds.midX, y: bounds.midY)
        let radius = min(bounds.width, bounds.height) / 2 - 1
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let path = CGMutablePath()
        let rays = 8
        for i in 0..<rays {
            let angle = CGFloat(i) / CGFloat(rays) * .pi * 2
            let length = i % 2 == 0 ? radius : radius * 0.62
            path.move(to: CGPoint(x: center.x + cos(angle) * radius * 0.18, y: center.y + sin(angle) * radius * 0.18))
            path.addLine(to: CGPoint(x: center.x + cos(angle) * length, y: center.y + sin(angle) * length))
        }
        shape.path = path
        shape.lineWidth = max(1.4, radius * 0.24)
        CATransaction.commit()
    }

    func update(style: ClaudeSparkView.Style, color: NSColor) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shape.strokeColor = color.cgColor
        CATransaction.commit()
        guard style != self.style else { return }
        self.style = style
        shape.removeAllAnimations()
        shape.opacity = 1
        switch style {
        case .working:
            let spin = CABasicAnimation(keyPath: "transform.rotation.z")
            spin.fromValue = 0
            spin.toValue = -CGFloat.pi * 2
            spin.duration = 2.8
            spin.repeatCount = .infinity
            spin.preferredFrameRateRange = CAAnimation.ambientFrameRate
            shape.add(spin, forKey: "spin")
            let breathe = CABasicAnimation(keyPath: "transform.scale")
            breathe.fromValue = 0.82
            breathe.toValue = 1.0
            breathe.duration = 0.7
            breathe.autoreverses = true
            breathe.repeatCount = .infinity
            breathe.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            breathe.preferredFrameRateRange = CAAnimation.ambientFrameRate
            shape.add(breathe, forKey: "breathe")
        case .waiting:
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 1
            pulse.toValue = 0.3
            pulse.duration = 0.65
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            pulse.preferredFrameRateRange = CAAnimation.ambientFrameRate
            shape.add(pulse, forKey: "pulse")
        case .idle:
            break
        }
    }
}
