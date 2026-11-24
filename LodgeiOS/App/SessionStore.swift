import Foundation
import LodgeKit
import os

/// Reads the saved session (a `SessionFile` in Application Support/Lodge) at launch and writes it back, debounced, as
/// it changes; the app writes at once when it goes to the background. I/O errors are logged, never thrown.
@MainActor
final class SessionStore {
    private static let logger = Logger(subsystem: "dev.lodge", category: "session")

    private let directory: URL?
    private let debounce: Duration
    private var pending: SessionSnapshot?
    private var writeTask: Task<Void, Never>?

    /// `directory` nil means Application Support/Lodge.
    init(directory: URL? = nil, debounce: Duration = .milliseconds(500)) {
        self.directory = directory
        self.debounce = debounce
    }

    private lazy var file: SessionFile? = {
        if let directory { return SessionFile(directory: directory) }
        do {
            return SessionFile(directory: try Self.appDirectory())
        } catch {
            Self.logger.error("Cannot find Application Support: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }()

    nonisolated static func appDirectory() throws -> URL {
        try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        ).appending(path: "Lodge", directoryHint: .isDirectory)
    }

    /// The saved session; nil when there is none, or when it cannot be read (the file is then set aside).
    func load() -> SessionSnapshot? {
        guard let file else { return nil }
        let outcome = file.load()
        if case .setAside(let reason, _) = outcome {
            Self.logger.error("Cannot read the session, setting it aside: \(reason.localizedDescription, privacy: .public)")
        }
        return outcome.snapshot
    }

    func schedule(_ snapshot: SessionSnapshot) {
        pending = snapshot
        guard writeTask == nil else { return }
        writeTask = Task { [weak self, debounce] in
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled else { return }
            self?.writeTask = nil
            self?.writePending()
        }
    }

    func writeNow(_ snapshot: SessionSnapshot) {
        pending = snapshot
        writeTask?.cancel()
        writeTask = nil
        writePending()
    }

    private func writePending() {
        guard let snapshot = pending, let file else { return }
        pending = nil
        do {
            try file.write(snapshot)
        } catch {
            Self.logger.error("Cannot write the session: \(error.localizedDescription, privacy: .public)")
        }
    }
}
