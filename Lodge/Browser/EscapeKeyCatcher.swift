import AppKit
import SwiftUI

/// Runs `action` for Esc in the window it sits in, ahead of the first responder, so a page that keeps
/// Escape for itself, or a field under a floating surface, never holds that surface open.
struct EscapeKeyCatcher: NSViewRepresentable {
    let action: () -> Void

    func makeNSView(context: Context) -> CatcherView { CatcherView() }

    func updateNSView(_ view: CatcherView, context: Context) { view.action = action }

    static func dismantleNSView(_ view: CatcherView, coordinator: ()) { view.stop() }

    final class CatcherView: NSView {
        var action: () -> Void = {}
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard event.keyCode == 53, event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
                    let target = event.window.map(ObjectIdentifier.init)
                else { return event }
                let handled = MainActor.assumeIsolated {
                    guard let self, let window = self.window, ObjectIdentifier(window) == target else { return false }
                    self.action()
                    return true
                }
                return handled ? nil : event
            }
        }

        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}
