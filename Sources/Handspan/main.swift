import AppKit

// Unbuffered so console logs show up immediately even when stdout is redirected to a file.
setbuf(stdout, nil)

/// Renders the handpan view off-screen to a PNG, bypassing the need for
/// Screen Recording permission (this is the app drawing itself, not a
/// screen capture). Useful for previewing UI changes headlessly.
func writeSnapshot(to path: String) {
    let frame = NSRect(x: 0, y: 0, width: 1000, height: 625)
    let view = HandpanView(frame: frame)
    guard let rep = view.bitmapImageRepForCachingDisplay(in: frame) else {
        FileHandle.standardError.write("Failed to create bitmap rep\n".data(using: .utf8)!)
        exit(1)
    }
    rep.size = frame.size
    view.cacheDisplay(in: frame, to: rep)
    guard let data = rep.representation(using: .png, properties: [:]) else {
        FileHandle.standardError.write("Failed to encode PNG\n".data(using: .utf8)!)
        exit(1)
    }
    do {
        try data.write(to: URL(fileURLWithPath: path))
        print("Wrote snapshot to \(path)")
    } catch {
        FileHandle.standardError.write("Failed to write file: \(error)\n".data(using: .utf8)!)
        exit(1)
    }
}

if let snapshotIndex = CommandLine.arguments.firstIndex(of: "--snapshot"), snapshotIndex + 1 < CommandLine.arguments.count {
    writeSnapshot(to: CommandLine.arguments[snapshotIndex + 1])
    exit(0)
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private var handpanView: HandpanView!

    func applicationDidFinishLaunching(_ notification: Notification) {
        let contentRect = NSRect(x: 0, y: 0, width: 1000, height: 625)
        window = NSWindow(
            contentRect: contentRect,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Handspan"
        window.center()
        handpanView = HandpanView(frame: contentRect)
        window.contentView = handpanView
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(handpanView)

        NSApp.activate(ignoringOtherApps: true)

        // A soft welcome touch shortly after launch, in the instrument's own voice.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.handpanView.playStartupChime()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
