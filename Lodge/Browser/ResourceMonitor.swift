#if DEBUG
    import AppKit
    import LodgeKit
    import SwiftUI

    /// Debug › Resource Monitor (D1): one utility window at normal level, so it never competes with the mini player's
    /// panel, showing Lodge's own CPU and footprint and its counters (D4). It samples only while some of it is on screen,
    /// and a closed window is let go, so the next `show` builds a fresh one.
    @MainActor
    final class ResourceMonitor: NSObject, NSWindowDelegate {
        private static var shared: ResourceMonitor?

        private let sampler: ResourceSampler
        private let window: NSPanel

        /// Opens the window, or brings it front when it is already open.
        static func show(coordinator: WorkspaceCoordinator) {
            let monitor = shared ?? ResourceMonitor(coordinator: coordinator)
            shared = monitor
            monitor.sampler.start()
            monitor.window.makeKeyAndOrderFront(nil)
        }

        private init(coordinator: WorkspaceCoordinator) {
            sampler = ResourceSampler { [weak coordinator] in
                coordinator.map(ResourceCounters.init(coordinator:)) ?? ResourceCounters()
            }
            window = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 360, height: 220),
                styleMask: [.titled, .closable, .resizable, .utilityWindow], backing: .buffered, defer: true)
            super.init()
            window.title = "Resource Monitor"
            window.isFloatingPanel = false
            window.level = .normal
            window.hidesOnDeactivate = false
            window.isReleasedWhenClosed = false
            window.contentViewController = NSHostingController(rootView: ResourceMonitorView(sampler: sampler))
            window.delegate = self
            window.center()
        }

        func windowWillClose(_ notification: Notification) {
            sampler.stop()
            // Let go once AppKit has finished closing the window, unless it was shown again meanwhile.
            Task { @MainActor in
                if Self.shared === self, !window.isVisible { Self.shared = nil }
            }
        }

        /// Covered by other windows or hidden with the app: nothing to show, so nothing to sample.
        func windowDidChangeOcclusionState(_ notification: Notification) {
            if window.occlusionState.contains(.visible) { sampler.start() } else { sampler.stop() }
        }
    }

    private struct ResourceMonitorView: View {
        let sampler: ResourceSampler

        var body: some View {
            VStack(alignment: .leading, spacing: 12) {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                    let reading = sampler.reading
                    row("Lodge CPU", reading.cpuText)
                    row("Lodge footprint", reading.footprintText)
                    Divider()
                    row("Live web views", "\(reading.counters.liveWebViews)")
                    row("Held tabs", "\(reading.counters.heldTabs)")
                    row("Mini player", reading.counters.miniPlayerText)
                    row("Workspaces loaded", "\(reading.counters.workspacesLoaded)")
                }
                Spacer(minLength: 0)
                Text(Self.helpersNote)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(16)
            .frame(minWidth: 320, minHeight: 200, alignment: .topLeading)
        }

        /// WebKit's helper processes are hidden from the sandbox, so the terminal tool measures them.
        private static let helpersNote =
            (try? AttributedString(markdown: "WebKit helpers: run `make perf` in Terminal"))
            ?? AttributedString("WebKit helpers: run make perf in Terminal")

        private func row(_ label: String, _ value: String) -> some View {
            GridRow {
                Text(verbatim: label).foregroundStyle(.secondary)
                Text(verbatim: value).monospacedDigit()
            }
        }
    }
#endif
