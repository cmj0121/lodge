import Foundation

/// File names for downloads: safe on disk, and never one that is taken.
public enum DownloadNaming {
    /// A download is written to `<final name>.lodgedownload` and renamed on finish.
    public static let partialExtension = "lodgedownload"

    static let maxBytes = 200

    /// Last path component only; "/", ":", "\\", control and format chars (bidi controls, zero-width chars) → "_";
    /// trims whitespace and dots at the ends; "", ".", ".." → "download"; at most 200 UTF-8 bytes, keeping the
    /// extension. Never returns "", "." or "..".
    public static func sanitize(_ suggested: String) -> String {
        let last = suggested.split(separator: "/", omittingEmptySubsequences: false).last.map(String.init) ?? ""
        var scalars = String.UnicodeScalarView()
        for scalar in last.unicodeScalars {
            let category = scalar.properties.generalCategory
            let unsafe = scalar == ":" || scalar == "\\" || category == .control || category == .format
            scalars.append(unsafe ? "_" : scalar)
        }
        let name = capped(trimmed(String(scalars)))
        return name.isEmpty || name == "." || name == ".." ? "download" : name
    }

    private static let trimmable = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "."))

    private static func trimmed(_ name: String) -> String {
        name.trimmingCharacters(in: trimmable)
    }

    /// The longest prefix of `text` within `bytes` UTF-8 bytes, in whole characters, else in whole scalars when
    /// not even the first character fits.
    private static func prefix(of text: String, bytes: Int) -> String {
        var characters = Substring(text)
        while characters.utf8.count > bytes { characters.removeLast() }
        guard characters.isEmpty else { return String(characters) }
        var scalars = String.UnicodeScalarView()
        var used = 0
        for scalar in text.unicodeScalars {
            used += String(scalar).utf8.count
            guard used <= bytes else { break }
            scalars.append(scalar)
        }
        return String(scalars)
    }

    /// Shortens the base so `name` fits in `maxBytes` with its extension intact; an extension too long to keep is
    /// cut along with the rest.
    private static func capped(_ name: String) -> String {
        guard name.utf8.count > maxBytes else { return name }
        let (base, ext) = split(name)
        if let ext, ext.utf8.count + 1 < maxBytes {
            let kept = trimmed(prefix(of: base, bytes: maxBytes - 1 - ext.utf8.count))
            if !kept.isEmpty { return kept + "." + ext }
        }
        return trimmed(prefix(of: name, bytes: maxBytes))
    }

    /// "a.tar.gz" → ("a.tar", "gz"); a name without a dot, or a dotfile like ".env", has no extension.
    private static func split(_ name: String) -> (base: String, ext: String?) {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex, name.index(after: dot) != name.endIndex
        else { return (name, nil) }
        return (String(name[..<dot]), String(name[name.index(after: dot)...]))
    }

    /// `name`, else "base (1).ext", "base (2).ext", … — skipping names that exist (final or `.lodgedownload`)
    /// in `directory` or are in `reserved`.
    public static func unique(
        _ name: String, in directory: URL, reserved: Set<String>,
        exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    ) -> String {
        // APFS is case-insensitive by default, so "A.zip" takes "a.zip" too.
        let reserved = Set(reserved.map { $0.lowercased() })
        func isTaken(_ candidate: String) -> Bool {
            let partial = candidate + "." + partialExtension
            return reserved.contains(candidate.lowercased()) || reserved.contains(partial.lowercased())
                || exists(directory.appending(path: candidate)) || exists(directory.appending(path: partial))
        }
        guard isTaken(name) else { return name }
        let (base, ext) = split(name)
        var number = 1
        while true {
            let candidate = "\(base) (\(number))" + (ext.map { "." + $0 } ?? "")
            if !isTaken(candidate) { return candidate }
            number += 1
        }
    }

    /// Appends ".lodgedownload".
    public static func partialURL(for finalURL: URL) -> URL {
        finalURL.appendingPathExtension(partialExtension)
    }
}
