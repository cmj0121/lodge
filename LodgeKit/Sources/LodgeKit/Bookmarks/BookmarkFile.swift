import CoreFoundation
import Foundation

/// Reading a bookmark file the user picked: its size cap, its text and the folder it imports into.
public enum BookmarkFile {
    public enum ReadError: Error, Equatable {
        case tooLarge
        case unreadable
    }

    /// The largest file an import reads, about 5 MB.
    public static let maxSize = 5 * 1024 * 1024

    /// The folder title for an import of `url`: the file's name without its extension, "Imported" when blank.
    public static func importTitle(for url: URL) -> String {
        let name = url.deletingPathExtension().lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "Imported" : name
    }

    /// The file's text: UTF-8, else the charset its `<meta>` declares, else Windows-1252; nil when none fits.
    public static func text(of data: Data) -> String? {
        if let text = String(data: data, encoding: .utf8) { return text }
        if let declared = declaredEncoding(in: data), let text = String(data: data, encoding: declared) { return text }
        return String(data: data, encoding: .windowsCP1252)
    }

    /// Reads, decodes and parses the file at `url` into a folder titled after it. Throws `.tooLarge` above
    /// `maxSize` bytes, `.unreadable` when it cannot be read or decoded, and `NetscapeBookmarks.ImportError`.
    public static func read(_ url: URL, maxSize: Int = maxSize) throws -> BookmarkFolder {
        guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
            let handle = try? FileHandle(forReadingFrom: url)
        else { throw ReadError.unreadable }
        defer { try? handle.close() }
        // Capped while reading, not by a size checked beforehand, so a file that grows meanwhile is still refused.
        guard let data = try? handle.read(upToCount: maxSize + 1) ?? Data() else { throw ReadError.unreadable }
        guard data.count <= maxSize else { throw ReadError.tooLarge }
        guard let html = text(of: data) else { throw ReadError.unreadable }
        return try NetscapeBookmarks.parse(html, title: importTitle(for: url))
    }

    /// The encoding named by a `charset=` in the file's first 4 KB; nil when there is none or it is unknown. As in
    /// the HTML spec, a declared UTF-16 or UTF-32 counts as UTF-8, so it is nil here too.
    static func declaredEncoding(in data: Data) -> String.Encoding? {
        guard let head = String(data: data.prefix(4096), encoding: .isoLatin1),
            let match = head.firstMatch(of: /(?i)charset\s*=\s*["']?\s*([-\w.:]+)/)
        else { return nil }
        let encoding = CFStringConvertIANACharSetNameToEncoding(String(match.1) as CFString)
        guard encoding != kCFStringEncodingInvalidId else { return nil }
        let declared = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(encoding))
        return wideEncodings.contains(declared) ? nil : declared
    }

    private static let wideEncodings: Set<String.Encoding> = [
        .utf16, .utf16BigEndian, .utf16LittleEndian, .utf32, .utf32BigEndian, .utf32LittleEndian,
    ]
}
