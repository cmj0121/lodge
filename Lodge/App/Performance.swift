import os

/// Signposts on Lodge's hot paths (D3), in every build, for Instruments' os_signpost tracks. A span opens with
/// `begin` and ends in a `defer`, so the method it times keeps its body as it was.
enum Performance {
    static let logger = Logger(subsystem: "dev.lodge", category: "perf")
    static let signposter = OSSignposter(logger: logger)

    /// Opens the signpost interval `name`; each gets its own id, so spans that overlap, such as async ones, stay apart.
    static func begin(_ name: StaticString) -> Span {
        Span(name: name, state: signposter.beginInterval(name, id: signposter.makeSignpostID()))
    }

    struct Span {
        fileprivate let name: StaticString
        fileprivate let state: OSSignpostIntervalState

        func end() {
            Performance.signposter.endInterval(name, state)
        }
    }
}

/// One tab's "pageLoad" interval (D3): opened when a main-frame navigation starts and ended when that navigation
/// finishes or fails, when a newer one replaces it, or when the tab goes away mid-load.
final class PageLoadSignpost {
    /// The navigation being timed (by identity only, so it is not kept alive) and its interval.
    private var open: (navigation: ObjectIdentifier?, span: Performance.Span)?

    func begin(_ navigation: AnyObject?) {
        end()
        open = (navigation.map(ObjectIdentifier.init), Performance.begin("pageLoad"))
    }

    /// Ends the interval when it is `navigation`'s; a load already replaced was ended then.
    func end(_ navigation: AnyObject?) {
        guard open?.navigation == navigation.map(ObjectIdentifier.init) else { return }
        end()
    }

    /// Ends whatever load is open.
    func end() {
        open?.span.end()
        open = nil
    }

    deinit {
        end()
    }
}
