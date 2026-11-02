import AppKit
import CoreImage

/// Softens the stock traffic lights in place (no custom buttons).
/// Muted by default; full color + opacity while the pointer is over the
/// native traffic-light cluster (buttons + gaps between them).
@MainActor
enum WindowTrafficLights {
    private static let mutedAlpha: CGFloat = 0.25
    private static let mutedSaturation: CGFloat = 0.0
    private static var mouseMonitor: Any?
    private static var hoveredWindow: ObjectIdentifier?
    private static var isHovered = false

    static func install() {
        if mouseMonitor == nil {
            mouseMonitor = NSEvent.addLocalMonitorForEvents(
                matching: [.mouseMoved, .leftMouseDragged, .mouseEntered, .mouseExited]
            ) { event in
                updateHover(for: event)
                return event
            }
        }

        NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { note in
            guard let window = note.object as? NSWindow else { return }
            Task { @MainActor in
                apply(muted: true, to: window)
            }
        }

        // SwiftUI may attach the titlebar a beat after launch.
        for delay in [0.0, 0.15, 0.5] as [TimeInterval] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                NSApp.windows.forEach { apply(muted: true, to: $0) }
            }
        }
    }

    static func deEmphasize(in window: NSWindow) {
        apply(muted: !isHovered || hoveredWindow != ObjectIdentifier(window), to: window)
    }

    private static func updateHover(for event: NSEvent) {
        let window = event.window ?? NSApp.keyWindow
        guard let window, isMainWindow(window) else {
            if isHovered {
                isHovered = false
                hoveredWindow = nil
                NSApp.windows.forEach { apply(muted: true, to: $0) }
            }
            return
        }

        // Titlebar events often have a nil `event.window`; then locationInWindow is screen space.
        let point: CGPoint
        if event.window != nil {
            point = event.locationInWindow
        } else {
            point = window.convertPoint(fromScreen: event.locationInWindow)
        }

        // Exact cluster bounds (includes gaps). No pad out / trim in — matches AppKit hover.
        let over = trafficLightClusterFrame(in: window).contains(point)
        let id = ObjectIdentifier(window)
        guard over != isHovered || (over && hoveredWindow != id) else { return }

        isHovered = over
        hoveredWindow = over ? id : nil
        apply(muted: !over, to: window)
        if over {
            for other in NSApp.windows where other !== window {
                apply(muted: true, to: other)
            }
        }
    }

    private static func isMainWindow(_ window: NSWindow) -> Bool {
        window.styleMask.contains(.titled) || window.styleMask.contains(.fullSizeContentView)
    }

    /// Bounding box of the three stoplight buttons in window coordinates (gaps included).
    private static func trafficLightClusterFrame(in window: NSWindow) -> CGRect {
        let types: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        let buttons = types.compactMap { window.standardWindowButton($0) }
        guard let first = buttons.first, let container = first.superview else {
            return .null
        }
        var union = first.frame
        for button in buttons.dropFirst() {
            union = union.union(button.frame)
        }
        return container.convert(union, to: nil)
    }

    private static func apply(muted: Bool, to window: NSWindow) {
        guard isMainWindow(window) else { return }

        let types: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        for type in types {
            guard let button = window.standardWindowButton(type) else { continue }
            button.alphaValue = muted ? mutedAlpha : 1.0
            button.wantsLayer = true
            guard let layer = button.layer else { continue }

            if muted {
                if let existing = layer.filters?.compactMap({ $0 as? CIFilter })
                    .first(where: { $0.name == "CIColorControls" }) {
                    existing.setValue(mutedSaturation, forKey: kCIInputSaturationKey)
                } else if let filter = CIFilter(name: "CIColorControls") {
                    filter.setValue(mutedSaturation, forKey: kCIInputSaturationKey)
                    filter.setValue(1.0, forKey: kCIInputBrightnessKey)
                    filter.setValue(1.0, forKey: kCIInputContrastKey)
                    layer.filters = (layer.filters ?? []) + [filter]
                }
            } else {
                layer.filters = layer.filters?.filter { filter in
                    (filter as? CIFilter)?.name != "CIColorControls"
                }
            }
        }
    }
}
