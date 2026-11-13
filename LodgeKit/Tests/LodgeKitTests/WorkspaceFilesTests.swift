import Foundation
import Testing

@testable import LodgeKit

@Suite final class WorkspaceFilesTests {
    private let app: URL

    init() throws {
        app = FileManager.default.temporaryDirectory.appending(
            path: "WorkspaceFilesTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: app)
    }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) }

    private func make(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: url)
    }

    @Test func defaultKeepsTheAppDirectory() {
        #expect(WorkspaceFiles.historyDirectory(for: .default, in: app) == app)
    }

    @Test func aCustomWorkspaceHasItsOwnDirectory() {
        let workspace = Workspace(name: "Work", symbol: "briefcase")
        let expected = app.appending(path: "Workspaces/\(workspace.id.uuidString)", directoryHint: .isDirectory)
        #expect(WorkspaceFiles.historyDirectory(for: workspace, in: app) == expected)
        #expect(WorkspaceFiles.directory(for: workspace.id, in: app) == expected)
    }

    @Test func anAnonymousWorkspaceKeepsNoHistory() {
        let workspace = Workspace(name: "Private", symbol: "eye.slash", kind: .anonymous)
        #expect(WorkspaceFiles.historyDirectory(for: workspace, in: app) == nil)
    }

    @Test func removeDeletesTheWholeDirectory() throws {
        let id = UUID()
        let directory = WorkspaceFiles.directory(for: id, in: app)
        for name in ["history.sqlite", "history.sqlite-wal", "history.sqlite-shm", "history.sqlite.bad"] {
            try make(directory.appending(path: name))
        }
        try WorkspaceFiles.remove(id, in: app)
        #expect(!exists(directory))
    }

    @Test func removingAMissingDirectorySucceeds() throws {
        try WorkspaceFiles.remove(UUID(), in: app)
    }

    @Test func removeNeverTouchesDefaultsFiles() throws {
        let defaultFile = app.appending(path: "history.sqlite")
        let other = UUID()
        try make(defaultFile)
        try make(WorkspaceFiles.directory(for: other, in: app).appending(path: "history.sqlite"))
        try WorkspaceFiles.remove(Workspace.defaultID, in: app)
        try WorkspaceFiles.remove(other, in: app)
        #expect(exists(defaultFile))
    }
}
