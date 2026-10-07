#if DEBUG
import AppKit

/// Debug-only remote control, so the UI can be inspected from a shell:
///   swift scripts/debug-notch.swift peek /tmp/out
/// Posts `dev.upthere.debug` with `mode` (collapsed|peek-left|peek-right|peek|expanded)
/// and an optional `snapshot` directory that receives left.png/right.png.
enum DebugBridge {
    nonisolated(unsafe) private static var observer: NSObjectProtocol?

    static func install(model: NotchViewModel, panels: @escaping @MainActor @Sendable () -> [(String, NSView)]) {
        observer = DistributedNotificationCenter.default().addObserver(
            forName: .init("dev.upthere.debug"), object: nil, queue: .main
        ) { note in
            let mode = note.userInfo?["mode"] as? String
            let dir = note.userInfo?["snapshot"] as? String
            MainActor.assumeIsolated {
                switch mode {
                case "collapsed": model.debugSetMode(.collapsed)
                case "peek", "peek-center": model.debugSetMode(.peek(.center))
                case "peek-left": model.debugSetMode(.peek(.left))
                case "peek-right": model.debugSetMode(.peek(.right))
                case "expanded": model.debugSetMode(.expanded)
                default: break
                }
                guard let dir else { return }
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(900))
                    for (name, view) in panels() { snapshot(view, to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png")) }
                }
            }
        }
    }

    private static func snapshot(_ view: NSView, to url: URL) {
        guard view.bounds.width > 0, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
#endif
