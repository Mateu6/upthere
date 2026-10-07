#if DEBUG
import AppKit

/// Debug-only remote control, so the UI can be inspected from a shell:
///   swift scripts/debug-notch.swift peek /tmp/out
/// Posts `dev.upthere.debug` with `mode` (collapsed|peek-left|peek-right|peek|expanded|check-updates)
/// and an optional `snapshot` directory that receives left.png/right.png.
enum DebugBridge {
    nonisolated(unsafe) private static var observer: NSObjectProtocol?

    static func install(model: NotchViewModel, actions: NotchActions, panels: @escaping @MainActor @Sendable () -> [(String, NSView)]) {
        observer = DistributedNotificationCenter.default().addObserver(
            forName: .init("dev.upthere.debug"), object: nil, queue: .main
        ) { note in
            let mode = note.userInfo?["mode"] as? String
            let dir = note.userInfo?["snapshot"] as? String
            let delay = Int(note.userInfo?["delay"] as? String ?? "") ?? 900
            MainActor.assumeIsolated {
                switch mode {
                case "collapsed": model.debugSet(left: .collapsed, right: .collapsed)
                case "peek": model.debugSet(left: .peek, right: .peek)
                case "peek-left": model.debugSet(left: .peek, right: .collapsed)
                case "peek-right": model.debugSet(left: .collapsed, right: .peek)
                case "expanded": model.debugSet(left: .expanded, right: .expanded)
                case "expanded-right": model.debugSet(left: .collapsed, right: .expanded)
                case "check-updates": actions.checkForUpdates()
                case "hud-volume": model.debugShowHUD(.volume(0.62), side: .right)
                case "hud-seek": model.debugShowHUD(.seek((model.nowPlaying.current?.duration ?? 200) * 0.4), side: .right)
                case "theme-aurora": model.prefs.theme = .aurora
                case "theme-classic": model.prefs.theme = .classic
                case "theme-clear": model.prefs.theme = .clear
                case "clear-fade-on": model.prefs.clearBlackFade = true
                case "clear-fade-off": model.prefs.clearBlackFade = false
                case "glass-clear": model.prefs.glassTint = .clear
                case "glass-color": model.prefs.glassTint = .color
                default: break
                }
                guard let dir else { return }
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(delay))
                    for (name, view) in panels() { snapshot(view, to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png")) }
                    let g = model.geometry
                    let rect = CGRect(
                        x: g.notchRect.midX - 560, y: g.screenFrame.maxY - g.notchRect.maxY,
                        width: 1120, height: g.height + 34)
                    captureOwnWindows(rect: rect, to: URL(fileURLWithPath: dir).appendingPathComponent("window.png"))
                    // Lets tooling overlay the physical notch on the capture.
                    try? "\(g.notchWidth) \(g.height)".write(
                        to: URL(fileURLWithPath: dir).appendingPathComponent("notch.txt"), atomically: true, encoding: .utf8)
                }
            }
        }
    }

    /// Composites the app's own on-screen windows in the given rect (screen
    /// coordinates, top-left origin) — includes glass and Core Animation.
    static func captureOwnWindows(rect: CGRect, to url: URL) {
        typealias Fn = @convention(c) (CGRect, CFArray, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let handle = dlopen(nil, RTLD_NOW), let sym = dlsym(handle, "CGWindowListCreateImageFromArray") else { return }
        let create = unsafeBitCast(sym, to: Fn.self)
        let ids = NSApp.windows.filter(\.isVisible).map { UInt32($0.windowNumber) }
        guard !ids.isEmpty else { return }
        var pointers = ids.map { UnsafeRawPointer(bitPattern: UInt($0)) }
        let array = CFArrayCreate(nil, &pointers, pointers.count, nil)!
        // kCGWindowImageBestResolution = 1 << 3
        guard let image = create(rect, array, 0, 1 << 3)?.takeRetainedValue() else { return }
        let rep = NSBitmapImageRep(cgImage: image)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    private static func snapshot(_ view: NSView, to url: URL) {
        guard view.bounds.width > 0, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
#endif
