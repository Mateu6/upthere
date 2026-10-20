import AppKit
import SwiftUI

/// Hovering, clicking and the pointer monitors that open and close ears.
extension NotchViewModel {
    /// Width of the piece next to the notch that stays as it is while the
    /// rest of the ear opens.
    func innerPieceWidth(_ side: NotchSide) -> CGFloat? {
        let c = content
        switch side {
        case .left:
            if case .claudePiece(let part) = c.left, part != .none { return claudePieceWidth }
        case .right:
            if case .musicWithTimers = c.right { return musicPieceWidth }
        case .center: break
        }
        return nil
    }

    /// Whether the pointer is over `side`'s inner piece (screens without a notch).
    func cursorOverInnerPiece(_ side: NotchSide) -> Bool {
        guard let inner = innerPieceWidth(side) else { return false }
        let x = NSEvent.mouseLocation.x
        let distance = side == .left ? geometry.notchRect.minX - x : x - geometry.notchRect.maxX
        return distance < inner
    }

    /// A closed ear's inner piece counts as the notch for hovering: only the
    /// outer piece opens the ear.
    func overInnerPiece(_ side: NotchSide, distance: CGFloat) -> Bool {
        mode(side) == .collapsed && innerPieceWidth(side).map { distance < $0 } == true
    }

    /// A strip chip shows its buttons once the pointer rests on it. Sweeping
    /// across the strip changes nothing: whichever chip is open stays open
    /// until the pointer settles on another (they swap in one move) or
    /// leaves the chips (it folds away).
    func hoverChip(_ chip: TrayChip, inside: Bool) {
        if inside {
            pointedChip = chip
        } else if pointedChip == chip {
            pointedChip = nil
        }
        chipSettleTask?.cancel()
        guard pointedChip != hoveredChip else { return }
        let delay: Duration = pointedChip == nil ? Self.chipLeaveDelay : Self.chipRestDelay
        chipSettleTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, self.hoveredChip != self.pointedChip else { return }
            self.showButtons(of: self.pointedChip)
        }
    }

    /// One move for the whole strip: the old chip's buttons fold, the new
    /// one's open and every chip beyond them slides, all on the same spring
    /// the ear's mask picks for that change (opening when the strip grows).
    private func showButtons(of chip: TrayChip?) {
        let opening = chipButtonsWidth(chip) >= chipButtonsWidth(hoveredChip)
        withAnimation(Theme.earSpring(opening: opening)) { hoveredChip = chip }
    }

    /// How long the pointer rests on a chip before its buttons open: longer
    /// than a fast sweep spends crossing one.
    static let chipRestDelay: Duration = .milliseconds(180)
    /// How long after leaving the chips the open one folds away.
    static let chipLeaveDelay: Duration = .milliseconds(250)

    /// A chip that went away (its ear closed, or it was stopped) shows nothing.
    func chipGone(_ chip: TrayChip) {
        if pointedChip == chip { pointedChip = nil }
        guard hoveredChip == chip else { return }
        chipSettleTask?.cancel()
        showButtons(of: nil)
    }

    // MARK: Interaction

    /// Hover enter/exit events only say "something changed": what is hovered
    /// is read from the cursor's actual position (events from two panels can
    /// arrive in any order). Only the ear under the pointer opens; the notch
    /// itself opens nothing. An ear the pointer left stays open for the
    /// user's chosen delay.
    func hover(_ region: NotchSide, inside: Bool) {
        #if DEBUG
        if debugHold { return }
        #endif
        let region = regionUnderCursor()
        // Pointer moves only matter when they cross into another region.
        if inside, region == lastHoverRegion { return }
        lastHoverRegion = region
        for side in [NotchSide.left, .right] {
            if region == side {
                closeTasks.removeValue(forKey: side)?.cancel()
                guard mode(side) == .collapsed, openTasks[side] == nil else { continue }
                if nudgedSide != side { nudgedSide = side }
                // Hover intent: ignore the cursor just passing through the menu bar.
                openTasks[side] = Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(70))
                    guard !Task.isCancelled, let self else { return }
                    self.openTasks[side] = nil
                    if self.regionUnderCursor() == side { self.setMode(side, .peek) }
                }
            } else {
                openTasks.removeValue(forKey: side)?.cancel()
                if nudgedSide == side { nudgedSide = nil }
                guard mode(side) != .collapsed, closeTasks[side] == nil else { continue }
                let delay = mode(side) == .expanded ? max(prefs.earCloseDelay, 0.6) : prefs.earCloseDelay
                closeTasks[side] = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(delay))
                    guard !Task.isCancelled, let self else { return }
                    self.closeTasks[side] = nil
                    // Back over the ear (its enter may have been lost): note
                    // it, so the next move away closes it again.
                    if self.regionUnderCursor() != side { self.collapse(side) } else { self.lastHoverRegion = side }
                }
            }
        }
    }

    /// Which part of the notch is under the cursor: an ear (with its
    /// shoulder), the notch itself, or nothing.
    func regionUnderCursor(at point: CGPoint? = nil) -> NotchSide? {
        let p = point ?? NSEvent.mouseLocation
        let g = geometry
        guard p.y >= g.screenFrame.maxY - g.height - 1, p.y <= g.screenFrame.maxY + 1 else { return nil }
        let left = leftWidth > 0 ? leftWidth + Theme.shoulderRadius : 0
        let right = rightWidth > 0 ? rightWidth + Theme.shoulderRadius : 0
        if p.x >= g.notchRect.minX && p.x <= g.notchRect.maxX { return g.hasNotch || left + right > 0 ? .center : nil }
        if p.x < g.notchRect.minX && p.x >= g.notchRect.minX - left {
            return overInnerPiece(.left, distance: g.notchRect.minX - p.x) ? .center : .left
        }
        if p.x > g.notchRect.maxX && p.x <= g.notchRect.maxX + right {
            return overInnerPiece(.right, distance: p.x - g.notchRect.maxX) ? .center : .right
        }
        return nil
    }


    #if DEBUG

    func debugSet(left: EarMode, right: EarMode) {
        debugHold = left != .collapsed || right != .collapsed
        setMode(.left, left)
        setMode(.right, right)
    }

    func debugShowHUD(_ value: HUD, side: NotchSide) {
        setMode(side, .peek)
        showHUD(value, side: side, hold: .seconds(3))
    }
    #endif

    /// Click on an ear: expand it, or back to a peek if it's expanded.
    /// Music ears don't expand: everything (seek bar included) is already
    /// there on hover.
    func tap(_ side: NotchSide) {
        guard side != .center, !showsMusic(side) else { return }
        openTasks.removeValue(forKey: side)?.cancel()
        if mode(side) == .expanded {
            setMode(side, .peek)
        } else {
            setMode(side, .expanded)
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
    }

    func collapse(_ side: NotchSide) {
        guard side != .center else { return }
        openTasks.removeValue(forKey: side)?.cancel()
        closeTasks.removeValue(forKey: side)?.cancel()
        if hudSide == side {
            hudTask?.cancel()
            hud = nil
        }
        if nudgedSide == side { nudgedSide = nil }
        if side == .left { selectedSessionID = nil }
        setMode(side, .collapsed)
    }

    func collapseAll() {
        collapse(.left)
        collapse(.right)
    }

    /// While an ear is expanded, a click anywhere else collapses it. The
    /// global monitor only exists in that state, so it costs nothing otherwise.
    func updateOutsideClickMonitor() {
        let expanded = leftMode == .expanded || rightMode == .expanded
        if expanded, outsideClickMonitor == nil {
            outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) {
                [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    for side in [NotchSide.left, .right] where self.mode(side) == .expanded { self.collapse(side) }
                }
            }
        } else if !expanded, let monitor = outsideClickMonitor {
            NSEvent.removeMonitor(monitor)
            outsideClickMonitor = nil
        }
    }

    /// The panels' hover exit can get lost (a fast flick away, or an ear
    /// shrinking out from under a still pointer), leaving an ear open. While
    /// any ear is open, pointer moves elsewhere re-check what's hovered; the
    /// monitor only exists in that state and sees no events over our panels.
    func updatePointerMonitor() {
        let open = leftMode != .collapsed || rightMode != .collapsed
        if open, pointerMonitor == nil {
            pointerMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) {
                [weak self] _ in
                MainActor.assumeIsolated { self?.hover(.center, inside: true) }
            }
        } else if !open, let monitor = pointerMonitor {
            NSEvent.removeMonitor(monitor)
            pointerMonitor = nil
        }
    }
}
