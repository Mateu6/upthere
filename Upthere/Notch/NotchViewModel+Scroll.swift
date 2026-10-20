import AppKit

/// Scrolling over the ears (seek, volume, switching chats) and the seek bar.
extension NotchViewModel {
    enum HUD: Equatable {
        case volume(Float)
    }

    enum ScrollAxis { case horizontal, vertical }

    /// Horizontal scroll over the music ear seeks; vertical changes the
    /// system volume. The axis is locked per gesture so diagonal swipes don't
    /// do both. Returns whether the event was consumed.
    func scroll(_ event: NSEvent, side: NotchSide) -> Bool {
        if side == .left, cursorOverClaude() {
            // Several chats: scrolling switches between them. One chat:
            // sideways scrolls its rolling description.
            return claude.visibleSessions.count > 1 ? scrollSessions(event) : scrubStatus(event, with: leftStatusScrub)
        }
        if side == .right, case .claudeTool = content.right { return scrubStatus(event, with: rightStatusScrub) }
        guard showsMusic(side), let current = nowPlaying.current else { return false }
        // Momentum is ignored, except that a sideways swipe over Up Next keeps
        // gliding the list.
        if !event.momentumPhase.isEmpty { return !(side == .left && showsQueue && scrollAxis == .horizontal) }

        let now = Date.now
        if event.phase.contains(.began) || now.timeIntervalSince(lastScroll) > 0.35 { scrollAxis = nil }
        lastScroll = now

        // Device direction: positive = fingers right / up, regardless of natural scrolling.
        let inverted = event.isDirectionInvertedFromDevice
        let dx = inverted ? event.scrollingDeltaX : -event.scrollingDeltaX
        let dy = inverted ? -event.scrollingDeltaY : event.scrollingDeltaY
        if scrollAxis == nil {
            guard abs(dx) > 0.5 || abs(dy) > 0.5 else { return true }
            scrollAxis = abs(dx) > abs(dy) ? .horizontal : .vertical
        }
        let precise = event.hasPreciseScrollingDeltas
        // Sideways over Up Next scrolls the list, not the track.
        if scrollAxis == .horizontal && side == .left && showsQueue { return false }
        // As before: scrolling a closed music ear opens it. The only exception
        // is a piece beside the (virtual) notch, whose neighbor shouldn't open.
        if mode(side) == .collapsed && !cursorOverInnerPiece(side) { setMode(side, .peek) }

        switch scrollAxis {
        case .horizontal where prefs.scrollToSeek:
            guard let duration = current.duration, duration > 0 else { return true }
            let base = seekPreview ?? current.position()
            let target = min(duration, max(0, base + Double(dx) * (precise ? 0.35 : 4)))
            previewSeek(target)
            let delay = event.phase.contains(.ended) ? 0 : 280
            seekTask?.cancel()
            seekTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(delay))
                guard !Task.isCancelled else { return }
                self?.endSeek(at: target, after: .milliseconds(700))
            }
        case .vertical where prefs.scrollForVolume:
            let base: Float
            if case .volume(let v) = hud { base = v } else { base = SystemVolume.volume ?? 0.5 }
            guard let value = SystemVolume.set(base + Float(dy) * (precise ? 0.004 : 0.04)) else { return true }
            showHUD(.volume(value), side: side, hold: .milliseconds(1100))
        default:
            return false
        }
        return true
    }

    // MARK: Switching chats


    /// Follows the system's scroll direction like any sideways list, at a
    /// gentle 0.6× (trackpad) or 14 pt per wheel notch; momentum glides it.
    func scrubStatus(_ event: NSEvent, with scrubber: MarqueeScrubber) -> Bool {
        let dx = event.scrollingDeltaX, dy = event.scrollingDeltaY
        guard abs(dx) > abs(dy) else { return false }
        let delta = event.hasPreciseScrollingDeltas ? -dx * 0.6 : -dx.sign(14)
        scrubber.scrub(by: delta)
        return true
    }

    /// Whether the pointer is over Claude's part of the left ear.
    func cursorOverClaude() -> Bool {
        switch content.left {
        case .claudeGlyph, .claudeDetail: return true
        case .claudePiece: return geometry.notchRect.minX - NSEvent.mouseLocation.x < claudePieceWidth
        default: return false
        }
    }

    /// Scrolling over Claude switches to the next or previous chat: one
    /// switch per gesture, after ~60 pt of trackpad travel or a wheel notch.
    func scrollSessions(_ event: NSEvent) -> Bool {
        guard claude.visibleSessions.count > 1 else { return false }
        let now = Date.now
        // A new gesture: fingers down, or the wheel resting for 0.45 s.
        if event.phase.contains(.began) || (event.phase.isEmpty && event.momentumPhase.isEmpty
            && now.timeIntervalSince(lastSessionScroll) > 0.45)
        {
            sessionScroll = 0
            sessionScrollLocked = false
        }
        lastSessionScroll = now
        // Momentum belongs to the gesture that already switched (or didn't).
        guard event.momentumPhase.isEmpty, !sessionScrollLocked else { return true }
        let inverted = event.isDirectionInvertedFromDevice
        let dy = inverted ? -event.scrollingDeltaY : event.scrollingDeltaY
        let dx = inverted ? event.scrollingDeltaX : -event.scrollingDeltaX
        let delta = abs(dy) >= abs(dx) ? dy : dx
        let step: Int
        if event.hasPreciseScrollingDeltas {
            sessionScroll += delta
            guard abs(sessionScroll) >= 60 else { return true }
            step = sessionScroll > 0 ? 1 : -1
        } else {
            guard abs(delta) >= 1 else { return true }
            step = delta > 0 ? 1 : -1
        }
        sessionScrollLocked = true
        sessionScroll = 0
        cycleSession(by: step)
        if mode(.left) == .collapsed, case .claudeGlyph = content.left { setMode(.left, .peek) }
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        return true
    }

    // MARK: Seek bar

    func seekBarHover(_ inside: Bool) {
        seekBarHovered = inside
        seekHoverTask?.cancel()
        if inside {
            seekHoverTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled, let self, self.seekBarHovered else { return }
                self.seekBarActive = true
            }
        } else if seekPreview == nil {
            seekBarActive = false
        }
    }

    /// While dragging or scrolling: grow the bar and show the target in it.
    func previewSeek(_ seconds: TimeInterval) {
        seekReleaseTask?.cancel()
        seekPreview = seconds
        if !seekBarActive { seekBarActive = true }
    }

    /// Seeks (if `commit`) and lets the preview go shortly after, so the bar
    /// doesn't snap back before the player catches up.
    func endSeek(at seconds: TimeInterval?, after delay: Duration = .milliseconds(450)) {
        if let seconds { nowPlaying.send(.seek(seconds)) }
        seekReleaseTask?.cancel()
        seekReleaseTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            self.seekPreview = nil
            if !self.seekBarHovered { self.seekBarActive = false }
        }
    }

    func showHUD(_ value: HUD, side: NotchSide, hold: Duration) {
        hudSide = side
        hud = value
        hudTask?.cancel()
        hudTask = Task { [weak self] in
            try? await Task.sleep(for: hold)
            guard !Task.isCancelled else { return }
            self?.hud = nil
        }
    }
}

private extension CGFloat {
    /// `magnitude` with this value's sign (0 stays 0).
    func sign(_ magnitude: CGFloat) -> CGFloat { self > 0 ? magnitude : self < 0 ? -magnitude : 0 }
}
