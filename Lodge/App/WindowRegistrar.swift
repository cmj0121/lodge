import AppKit
import SwiftUI

/// Sits in a browser window's background and hands the window's `NSWindow` to the coordinator once it is in one.
struct WindowRegistrar: NSViewRepresentable {
    let coordinator: WorkspaceCoordinator
    let window: WindowState

    func makeNSView(context: Context) -> RegistrarView {
        RegistrarView(register: { [coordinator, window] in coordinator.register(window, nsWindow: $0) })
    }

    func updateNSView(_ nsView: RegistrarView, context: Context) {}

    final class RegistrarView: NSView {
        private let register: (NSWindow) -> Void

        init(register: @escaping (NSWindow) -> Void) {
            self.register = register
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { register(window) }
        }
    }
}
