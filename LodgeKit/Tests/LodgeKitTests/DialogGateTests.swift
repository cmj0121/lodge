import Foundation
import Testing

@testable import LodgeKit

@Suite struct DialogGateTests {
    let start = ContinuousClock.now
    let example = Origin(scheme: "https", host: "example.com", port: 0)

    private func admissions(_ gate: inout DialogGate, atSeconds seconds: [Int]) -> [Bool] {
        seconds.map { gate.admit(at: start + .seconds($0)) }
    }

    @Test func admitsUpToTheLimitThenBlocks() {
        var gate = DialogGate()
        #expect(admissions(&gate, atSeconds: [0, 1, 2, 3, 60]) == [true, true, true, false, false])
        #expect(gate.isBlocked)
    }

    @Test func dialogsSpreadOutStayAllowed() {
        var gate = DialogGate()
        let seconds = Array(stride(from: 0, to: 100, by: 5))
        #expect(admissions(&gate, atSeconds: seconds).allSatisfy { $0 })
        #expect(!gate.isBlocked)
    }

    @Test func sameOriginCommitKeepsTheCountAndTheBlock() {
        var gate = DialogGate()
        gate.commit(origin: example)
        #expect(admissions(&gate, atSeconds: [0, 1]) == [true, true])
        gate.commit(origin: example)
        #expect(admissions(&gate, atSeconds: [2, 3]) == [true, false])
        gate.commit(origin: example)
        #expect(gate.isBlocked)

        var blocked = DialogGate()
        blocked.commit(origin: example)
        blocked.block()
        blocked.commit(origin: example)
        #expect(admissions(&blocked, atSeconds: [0]) == [false])
    }

    @Test func otherOriginCommitLiftsTheBlock() {
        var gate = DialogGate()
        gate.commit(origin: example)
        gate.block()
        gate.commit(origin: Origin(scheme: "https", host: "other.example", port: 0))
        #expect(!gate.isBlocked)
        #expect(admissions(&gate, atSeconds: [0]) == [true])
    }

    @Test(arguments: [
        ("https://example.com/a?b#c", "https://example.com"),
        ("https://Example.com/#other", "https://example.com"),
        ("http://localhost:3000/x", "http://localhost:3000"),
        ("file:///tmp/a.html", "file:"),
        ("about:blank", "about:"),
    ])
    func originOfAURL(url: String, expected: String) throws {
        #expect(Origin(url: try #require(URL(string: url))).description == expected)
    }

    @Test func sameOriginFromURLAndFromParts() throws {
        let url = try #require(URL(string: "https://example.com/page"))
        #expect(Origin(url: url) == example)
    }

    @Test(arguments: [
        ("https", "example.com", 0, "https://example.com says"),
        ("http", "localhost", 3000, "http://localhost:3000 says"),
        ("", "", 0, "An embedded page says"),
        ("file", "", 0, "file: says"),
    ])
    func titleNamesTheOrigin(scheme: String, host: String, port: Int, expected: String) {
        #expect(DialogGate.title(for: Origin(scheme: scheme, host: host, port: port)) == expected)
    }
}
