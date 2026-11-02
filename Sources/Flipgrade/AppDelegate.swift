import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        FlipgradeFont.registerBundledFonts()
        WindowTrafficLights.install()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        // Ensure at least one window is key/visible after launch from Terminal/`open`.
        DispatchQueue.main.async {
            if let window = NSApp.windows.first {
                window.makeKeyAndOrderFront(nil)
            } else {
                NSApp.windows.forEach { $0.makeKeyAndOrderFront(nil) }
            }
            NSApp.windows.forEach(WindowTrafficLights.deEmphasize(in:))
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
