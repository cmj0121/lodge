import Foundation

/// The `com.apple.quarantine` mark that makes Gatekeeper check a downloaded file before it runs (CWE-693).
public enum Quarantine {
    public static let attribute = "com.apple.quarantine"

    /// "0083;<seconds since 1970, hex>;<agent>;": flag 0x0083 marks it downloaded and not yet approved.
    public static func value(agent: String, at date: Date) -> String {
        String(format: "0083;%08x;%@;", UInt64(max(0, date.timeIntervalSince1970)), agent)
    }

    /// Adds the mark to `url` (itself, not a link's target) unless it has one already. Throws the `POSIXError`
    /// of a failed read or write.
    public static func ensure(_ url: URL, agent: String = "Lodge", at date: Date = Date()) throws {
        let path = url.path(percentEncoded: false)
        if getxattr(path, attribute, nil, 0, 0, XATTR_NOFOLLOW) >= 0 { return }
        guard errno == ENOATTR else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let bytes = Array(value(agent: agent, at: date).utf8)
        guard setxattr(path, attribute, bytes, bytes.count, 0, XATTR_NOFOLLOW) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    /// The mark on `url`, nil when it has none.
    public static func read(_ url: URL) -> String? {
        let path = url.path(percentEncoded: false)
        let size = getxattr(path, attribute, nil, 0, 0, XATTR_NOFOLLOW)
        guard size >= 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: size)
        guard getxattr(path, attribute, &bytes, size, 0, XATTR_NOFOLLOW) == size else { return nil }
        return String(decoding: bytes, as: UTF8.self)
    }
}

/// Where a downloaded file came from, as macOS records it beside the file.
public enum Provenance {
    public static let whereFromsAttribute = "com.apple.metadata:kMDItemWhereFroms"

    /// Removes the file's where-froms (its page and referrer) and replaces any quarantine mark with Lodge's, which
    /// names no origin, so a private download keeps no trace of the site it came from. Throws the `POSIXError` of a
    /// failed removal or write.
    public static func strip(_ url: URL, agent: String = "Lodge", at date: Date = Date()) throws {
        try removeWhereFroms(url)
        let path = url.path(percentEncoded: false)
        let bytes = Array(Quarantine.value(agent: agent, at: date).utf8)
        guard setxattr(path, Quarantine.attribute, bytes, bytes.count, 0, XATTR_NOFOLLOW) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    /// Clears a private download's origin with `strip`; when that fails, removes its where-froms and its quarantine
    /// mark (WebKit's or the sandbox's may name the origin) and marks it again as Lodge. `cleared` only when the
    /// where-froms are gone and the mark left is Lodge's own (`isOwnMark`); `errors` holds every `POSIXError` met,
    /// `strip`'s first, even when the fallback cleared it. No error names the file.
    public static func clear(
        _ url: URL, agent: String = "Lodge", at date: Date = Date()
    ) -> (cleared: Bool, errors: [any Error]) {
        do {
            try strip(url, agent: agent, at: date)
            return (true, [])
        } catch {
            var errors: [any Error] = [error]
            var removed = true
            do { try removeWhereFroms(url) } catch {
                errors.append(error)
                removed = false
            }
            let path = url.path(percentEncoded: false)
            if removexattr(path, Quarantine.attribute, XATTR_NOFOLLOW) != 0, errno != ENOATTR {
                errors.append(POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO))
            }
            do { try Quarantine.ensure(url, agent: agent, at: date) } catch { errors.append(error) }
            return (removed && isOwnMark(Quarantine.read(url), agent: agent), errors)
        }
    }

    /// Whether `mark` is exactly what Lodge writes (`Quarantine.value(agent:at:)`), which names no origin.
    public static func isOwnMark(_ mark: String?, agent: String = "Lodge") -> Bool {
        guard let fields = mark?.split(separator: ";", omittingEmptySubsequences: false), fields.count == 4 else {
            return false
        }
        return fields[0] == "0083" && !fields[1].isEmpty && fields[1].allSatisfy(\.isHexDigit)
            && fields[2] == agent && fields[3].isEmpty
    }

    /// Removes only the file's where-froms, the fallback when `strip` fails; a file without them is fine. Throws the
    /// `POSIXError` of a failed removal.
    public static func removeWhereFroms(_ url: URL) throws {
        if removexattr(url.path(percentEncoded: false), whereFromsAttribute, XATTR_NOFOLLOW) != 0, errno != ENOATTR {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}
