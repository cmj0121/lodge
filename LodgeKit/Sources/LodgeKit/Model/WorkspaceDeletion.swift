import Foundation

/// What deleting a workspace does, one step at a time, in the order `WorkspaceDeletion` runs them.
@MainActor
public protocol WorkspaceDeletionSteps: AnyObject {
    /// Takes the workspace off the list, moves the windows showing it to Default and marks it pending.
    func removeFromList(_ id: UUID)
    /// Writes the session file now, never through the debounced save.
    func saveNow()
    /// Closes its tabs, destroys their web views and drops its model and dormant content.
    func destroyViews(of id: UUID)
    /// Cancels its downloads still running; finished ones stay.
    func cancelDownloads(of id: UUID)
    func closeHistory(of id: UUID) async throws
    /// Evicts its cached website data store.
    func forgetStore(of id: UUID)
    func removeWebsiteData(of id: UUID) async throws
    func removeFiles(of id: UUID) throws
    /// Takes the workspace off the pending deletions.
    func clearPending(_ id: UUID)
}

/// Deletes a workspace so that a crash at any step leaves it pending, finished by `retry` at the next launch.
@MainActor
public enum WorkspaceDeletion {
    public static let dataRemovalAttempts = 3
    public static let dataRemovalDelay: Duration = .seconds(1)

    public typealias Sleep = @Sendable (Duration) async throws -> Void

    /// removeFromList → saveNow → destroyViews → cancelDownloads → closeHistory → forgetStore → removeWebsiteData
    /// (retried) → removeFiles → clearPending → saveNow. A failing step stops it, leaving the id pending; Default and
    /// Anonymous are refused. True when fully done.
    @discardableResult
    public static func run(
        _ id: UUID, steps: some WorkspaceDeletionSteps, sleep: Sleep = { try await Task.sleep(for: $0) }
    ) async -> Bool {
        guard !isFixed(id) else { return false }
        steps.removeFromList(id)
        steps.saveNow()
        steps.destroyViews(of: id)
        steps.cancelDownloads(of: id)
        do {
            try await steps.closeHistory(of: id)
        } catch {
            return false
        }
        steps.forgetStore(of: id)
        return await finish(id, steps: steps, sleep: sleep)
    }

    /// Launch retry, per id: removeWebsiteData (retried) → removeFiles → clearPending → saveNow. One that fails stays
    /// pending; the rest still run. Default and Anonymous are skipped.
    public static func retry(
        _ ids: [UUID], steps: some WorkspaceDeletionSteps, sleep: Sleep = { try await Task.sleep(for: $0) }
    ) async {
        for id in ids where !isFixed(id) {
            await finish(id, steps: steps, sleep: sleep)
        }
    }

    private static func isFixed(_ id: UUID) -> Bool {
        id == Workspace.defaultID || id == Workspace.anonymousID
    }

    @discardableResult
    private static func finish(_ id: UUID, steps: some WorkspaceDeletionSteps, sleep: Sleep) async -> Bool {
        do {
            try await removeWebsiteData(id, steps: steps, sleep: sleep)
            try steps.removeFiles(of: id)
        } catch {
            return false
        }
        steps.clearPending(id)
        steps.saveNow()
        return true
    }

    /// WebKit can still be letting go of the store just after its last view closed, so a failure is tried again.
    private static func removeWebsiteData(_ id: UUID, steps: some WorkspaceDeletionSteps, sleep: Sleep) async throws {
        for attempt in 1... {
            do {
                return try await steps.removeWebsiteData(of: id)
            } catch where attempt < dataRemovalAttempts {
                try await sleep(dataRemovalDelay)
            }
        }
    }
}
