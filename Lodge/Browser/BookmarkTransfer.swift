import AppKit
import LodgeKit
import UniformTypeIdentifiers

/// The Bookmarks menu's Import and Export: the file panels and the alerts for what goes wrong. Reading and
/// writing the file are the model's (`importBookmarks(from:)`, `exportBookmarks(to:)`).
@MainActor
enum BookmarkTransfer {
    /// Asks for one bookmark HTML file, then adds it to the bookmarks as a folder named after the file.
    static func importBookmarks(into model: BrowserModel) {
        let panel = NSOpenPanel()
        panel.message = "Choose a bookmark file exported from a browser."
        panel.prompt = "Import"
        panel.allowedContentTypes = [.html]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        present(panel) { url in
            Task {
                do {
                    try await model.importBookmarks(from: url)
                } catch {
                    show(importAlert(for: error, file: url.lastPathComponent))
                }
            }
        }
    }

    /// Asks where to save, then writes every bookmark there as one bookmark HTML file.
    static func exportBookmarks(from model: BrowserModel) {
        let panel = NSSavePanel()
        panel.message = "Other browsers can import this file."
        panel.prompt = "Export"
        panel.nameFieldStringValue = "Lodge Bookmarks.html"
        panel.allowedContentTypes = [.html]
        panel.canCreateDirectories = true
        present(panel) { url in
            // On the next turn, so an alert's sheet does not start while the panel's is still ending.
            Task {
                do {
                    try model.exportBookmarks(to: url)
                } catch {
                    let alert = NSAlert()
                    alert.messageText = "The bookmarks could not be exported."
                    alert.informativeText = error.localizedDescription
                    show(alert)
                }
            }
        }
    }

    private static func importAlert(for error: Error, file: String) -> NSAlert {
        let alert = NSAlert()
        switch error {
        case BookmarkFile.ReadError.tooLarge:
            alert.messageText = "“\(file)” is too large to import."
            alert.informativeText = "Bookmark files larger than 20 MB are not imported."
        case NetscapeBookmarks.ImportError.notABookmarkFile:
            alert.messageText = "“\(file)” is not a bookmark file."
            alert.informativeText =
                "Export the bookmarks from the other browser as an HTML file, then import that file."
        default:
            alert.messageText = "“\(file)” could not be read."
            alert.informativeText = "Check that the file still exists and is a text file."
        }
        return alert
    }

    private static var window: NSWindow? { NSApp.keyWindow ?? NSApp.mainWindow }

    /// Runs the panel as a sheet on the key window, or modal when there is none, and hands on the chosen file.
    private static func present(_ panel: NSSavePanel, then handle: @escaping (URL) -> Void) {
        let finish = { (response: NSApplication.ModalResponse) in
            if response == .OK, let url = panel.url { handle(url) }
        }
        if let window {
            panel.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(panel.runModal())
        }
    }

    private static func show(_ alert: NSAlert) {
        if let window {
            alert.beginSheetModal(for: window, completionHandler: nil)
        } else {
            alert.runModal()
        }
    }
}
