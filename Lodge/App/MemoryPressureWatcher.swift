import Dispatch
import LodgeKit

/// Hands the system's memory pressure warnings to the coordinator, which rests what it can (D4); a return to normal
/// does nothing. Watches from `init` until `cancel()` or until it goes.
@MainActor
final class MemoryPressureWatcher {
    private let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)

    init(coordinator: WorkspaceCoordinator) {
        source.setEventHandler { [weak coordinator, source] in
            MainActor.assumeIsolated {
                guard let coordinator, let level = MemoryPressureLevel(source.data) else { return }
                Task { await coordinator.relieve(level) }
            }
        }
        source.activate()
    }

    func cancel() {
        source.cancel()
    }

    isolated deinit {
        source.cancel()
    }
}

extension MemoryPressureLevel {
    /// The most pressing level in `event`; nil for a return to normal.
    fileprivate init?(_ event: DispatchSource.MemoryPressureEvent) {
        if event.contains(.critical) {
            self = .critical
        } else if event.contains(.warning) {
            self = .warning
        } else {
            return nil
        }
    }
}
