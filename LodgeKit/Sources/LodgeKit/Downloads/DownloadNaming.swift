import Foundation

/// File names for downloads: safe on disk, and never one that is taken.
public enum DownloadNaming {
    /// A download is written to `<final name>.lodgedownload` and renamed on finish.
    public static let partialExtension = "lodgedownload"

    static let maxBytes = 200

    /// Last path component only; "/", ":", "\\", control and format chars (bidi controls, zero-width chars) → "_";
    /// each run of separators (spaces of any width, U+2028, U+2029) → one " ", so a name cannot hide its extension
    /// behind blank space or a line break; trims whitespace and dots at the ends; "", ".", ".." → "download"; at
    /// most 200 UTF-8 bytes, keeping the extension. Never returns "", "." or "..".
    public static func sanitize(_ suggested: String) -> String {
        let last = suggested.split(separator: "/", omittingEmptySubsequences: false).last.map(String.init) ?? ""
        var scalars = String.UnicodeScalarView()
        for scalar in last.unicodeScalars {
            switch scalar.properties.generalCategory {
            case .spaceSeparator, .lineSeparator, .paragraphSeparator:
                if scalars.last != " " { scalars.append(" ") }
            case .control, .format:
                scalars.append("_")
            default:
                scalars.append(scalar == ":" || scalar == "\\" ? "_" : scalar)
            }
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

    /// One path component that is safe to put in a folder as is: not empty, ".", or "..", and without "/", ":",
    /// "\\", control or format chars.
    public static func isSafeComponent(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".."
            && !name.unicodeScalars.contains { scalar in
                let category = scalar.properties.generalCategory
                return "/:\\".unicodeScalars.contains(scalar) || category == .control || category == .format
            }
    }

    /// Numbered names tried before `unique` gives up counting.
    static let maxNumbered = 999

    /// `name`, else "base (1).ext", "base (2).ext", … up to "base (999).ext", then "base <8 hex of a UUID>.ext" —
    /// skipping names that exist (final or `.lodgedownload`, a dangling link included) in `directory` or are in
    /// `reserved`.
    public static func unique(
        _ name: String, in directory: URL, reserved: Set<String>,
        exists: (URL) -> Bool = { DownloadFiles.fileType(of: $0) != nil }
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
        let suffix = ext.map { "." + $0 } ?? ""
        for number in 1...maxNumbered {
            let candidate = "\(base) (\(number))" + suffix
            if !isTaken(candidate) { return candidate }
        }
        return "\(base) \(UUID().uuidString.prefix(8).lowercased())" + suffix
    }

    /// Appends ".lodgedownload".
    public static func partialURL(for finalURL: URL) -> URL {
        finalURL.appendingPathExtension(partialExtension)
    }
}
