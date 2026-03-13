import AppKit
import Foundation

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var server: WebSocketServer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Create menu bar status item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = createMenuBarIcon()

        // Create dropdown menu
        let menu = NSMenu()
        let titleItem = menu.addItem(
            withTitle: "Terminatab Running",
            action: nil,
            keyEquivalent: ""
        )
        titleItem.isEnabled = false
        menu.addItem(.separator())
        menu.addItem(
            withTitle: "Quit Terminatab",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        statusItem.menu = menu

        // Start WebSocket server on background
        let sessionManager = SessionManager()
        do {
            server = try WebSocketServer(port: 7681, sessionManager: sessionManager)
            server?.start()
            NSLog("terminatab-server starting on ws://127.0.0.1:7681")
        } catch {
            NSLog("Failed to start server: %@", error.localizedDescription)
        }
    }

    private func createMenuBarIcon() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size)
        image.lockFocus()

        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: NSColor.black,
        ]
        let text = "\u{276F}\u{23BD}" as NSString
        let textSize = text.size(withAttributes: attrs)
        let point = NSPoint(
            x: (size.width - textSize.width) / 2,
            y: (size.height - textSize.height) / 2
        )
        text.draw(at: point, withAttributes: attrs)

        image.unlockFocus()
        image.isTemplate = true
        return image
    }
}

// Use a C-level call for fork since Swift marks Darwin.fork() unavailable
@_silgen_name("fork") private func cFork() -> Int32

@main
struct TerminatabApp {
    static func main() {
        // Daemonize: fork so the shell returns immediately
        let pid = cFork()
        if pid < 0 { return }
        if pid > 0 { _exit(0) }

        // Child: new session, detach from terminal
        setsid()
        let devnull = open("/dev/null", O_RDWR)
        if devnull >= 0 {
            dup2(devnull, STDIN_FILENO)
            dup2(devnull, STDOUT_FILENO)
            dup2(devnull, STDERR_FILENO)
            if devnull > STDERR_FILENO { close(devnull) }
        }

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
