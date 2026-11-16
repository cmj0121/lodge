import AppKit

extension NSPasteboard {
    /// Replaces the contents with `url`, as a URL and as its text.
    func setURL(_ url: URL) {
        clearContents()
        writeObjects([url as NSURL])
        setString(url.absoluteString, forType: .string)
    }
}
