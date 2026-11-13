import Foundation
import Testing

@testable import LodgeKit

@Suite struct QuarantineTests {
    private let file = FileManager.default.temporaryDirectory.appending(path: "QuarantineTests-\(UUID()).zip")

    init() throws {
        try Data("x".utf8).write(to: file)
    }

    private func cleanUp() { try? FileManager.default.removeItem(at: file) }

    @Test func theValueIsTheDownloadedFormat() {
        let date = Date(timeIntervalSince1970: 0x6543_21AB)
        #expect(Quarantine.value(agent: "Lodge", at: date) == "0083;654321ab;Lodge;")
    }

    @Test func aFileWithoutTheMarkGetsOne() throws {
        defer { cleanUp() }
        removexattr(file.path(percentEncoded: false), Quarantine.attribute, 0)
        #expect(Quarantine.read(file) == nil)
        try Quarantine.ensure(file, at: Date(timeIntervalSince1970: 16))
        #expect(Quarantine.read(file) == "0083;00000010;Lodge;")
    }

    @Test func anExistingMarkIsKept() throws {
        defer { cleanUp() }
        let existing = Array("0081;00000001;Safari;".utf8)
        #expect(setxattr(file.path(percentEncoded: false), Quarantine.attribute, existing, existing.count, 0, 0) == 0)
        try Quarantine.ensure(file)
        #expect(Quarantine.read(file) == "0081;00000001;Safari;")
    }

    @Test func aMissingFileThrows() {
        #expect(throws: POSIXError.self) {
            try Quarantine.ensure(file.appendingPathExtension("missing"))
        }
        cleanUp()
    }
}
