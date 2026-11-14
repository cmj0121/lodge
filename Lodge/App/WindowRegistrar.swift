import AppKit
import LodgeKit
import SwiftUI

/// Sits in a browser window's background and hands the window's `NSWindow` to the coordinator once it is in one.
/// It also gives the window the look of the active workspace, on register and on every switch.
struct WindowRegistrar: NSViewRepresentable {
    let coordinator: WorkspaceCoordinator
    let window: WindowState
    /// The active workspace's kind; a change re-runs `updateNSView`.
    let workspace: WorkspaceKind

    func makeNSView(context: Context) -> RegistrarView {
        RegistrarView(workspace: workspace) { [coordinator, window] in coordinator.register(window, nsWindow: $0) }
    }

    func updateNSView(_ nsView: RegistrarView, context: Context) {
        nsView.workspace = workspace
    }

    final class RegistrarView: NSView {
        private let register: (NSWindow) -> Void
        var workspace: WorkspaceKind {
            didSet { applyAppearance() }
        }

        init(workspace: WorkspaceKind, register: @escaping (NSWindow) -> Void) {
            self.workspace = workspace
            self.register = register
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            applyAppearance()
            register(window)
        }

        private func applyAppearance() {
            if let window { WindowAppearance.apply(workspace, to: window) }
        }
    }
}
