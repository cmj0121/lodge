import Foundation
import LodgeKit
import os

/// Reads the saved session (a `SessionFile` in Application Support/Lodge) at launch and writes it back,
/// debounced, as it changes. I/O errors are logged, never thrown.
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

    /// The session file; nil when Application Support cannot be found.
    private lazy var file: SessionFile? = {
        if let directory { return SessionFile(directory: directory) }
        do {
            let support = try FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            return SessionFile(directory: support.appending(path: "Lodge", directoryHint: .isDirectory))
        } catch {
            Self.logger.error("Cannot find Application Support: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }()

    /// The saved session; nil when there is none, or when it cannot be read (the file is then set aside).
    func load() -> SessionSnapshot? {
        guard let outcome = file?.load() else { return nil }
        if case .setAside(let reason, let moveFailure) = outcome {
            Self.logger.error("Cannot read the session, setting it aside: \(reason.localizedDescription, privacy: .public)")
            if let moveFailure {
                Self.logger.error("Cannot set the session aside: \(moveFailure.localizedDescription, privacy: .public)")
            }
        }
        return outcome.snapshot
    }

    /// Writes `snapshot` once changes stop for `debounce`, replacing any snapshot still waiting. The app
    /// cannot be terminated suddenly while one waits.
    func schedule(_ snapshot: SessionSnapshot) {
        if pending == nil { ProcessInfo.processInfo.disableSuddenTermination() }
        pending = snapshot
        guard writeTask == nil else { return }
        writeTask = Task { [weak self, debounce] in
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled else { return }
            self?.writeTask = nil
            self?.writePending()
        }
    }

    /// Writes the waiting snapshot now.
    func flush() {
        writeTask?.cancel()
        writeTask = nil
        writePending()
    }

    private func writePending() {
        guard let snapshot = pending else { return }
        pending = nil
        defer { ProcessInfo.processInfo.enableSuddenTermination() }
        guard let file else { return }
        do {
            try file.write(snapshot)
        } catch {
            Self.logger.error("Cannot write the session: \(error.localizedDescription, privacy: .public)")
        }
    }
}
