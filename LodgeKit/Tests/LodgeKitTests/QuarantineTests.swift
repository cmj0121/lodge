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

    @Test func stripRemovesWhereFromsAndResetsTheMark() throws {
        defer { cleanUp() }
        let path = file.path(percentEncoded: false)
        let whereFroms = Array("https://secret.example/file.zip".utf8)
        #expect(setxattr(path, Provenance.whereFromsAttribute, whereFroms, whereFroms.count, 0, 0) == 0)
        let mark = Array("0081;00000001;Safari;1234-ABCD".utf8)
        #expect(setxattr(path, Quarantine.attribute, mark, mark.count, 0, 0) == 0)
        try Provenance.strip(file, at: Date(timeIntervalSince1970: 16))
        #expect(getxattr(path, Provenance.whereFromsAttribute, nil, 0, 0, 0) < 0)
        #expect(Quarantine.read(file) == "0083;00000010;Lodge;")
    }

    @Test func stripMarksAFileWithNoProvenance() throws {
        defer { cleanUp() }
        removexattr(file.path(percentEncoded: false), Quarantine.attribute, 0)
        try Provenance.strip(file, at: Date(timeIntervalSince1970: 16))
        #expect(Quarantine.read(file) == "0083;00000010;Lodge;")
    }

    @Test func clearLeavesOnlyLodgesMark() throws {
        defer { cleanUp() }
        let path = file.path(percentEncoded: false)
        let whereFroms = Array("https://secret.example/file.zip".utf8)
        #expect(setxattr(path, Provenance.whereFromsAttribute, whereFroms, whereFroms.count, 0, 0) == 0)
        let mark = Array("0081;00000001;WebKit;https://secret.example".utf8)
        #expect(setxattr(path, Quarantine.attribute, mark, mark.count, 0, 0) == 0)
        let result = Provenance.clear(file, at: Date(timeIntervalSince1970: 16))
        #expect(result.cleared && result.errors.isEmpty)
        #expect(getxattr(path, Provenance.whereFromsAttribute, nil, 0, 0, 0) < 0)
        #expect(Quarantine.read(file) == "0083;00000010;Lodge;")
    }

    @Test func clearOnAMissingFileReportsTheOriginKept() {
        let result = Provenance.clear(file.appendingPathExtension("missing"))
        #expect(!result.cleared)
        #expect(!result.errors.isEmpty && result.errors.allSatisfy { $0 is POSIXError })
        cleanUp()
    }

    @Test func onlyLodgesExactMarkIsItsOwn() {
        #expect(Provenance.isOwnMark("0083;00000010;Lodge;"))
        #expect(Provenance.isOwnMark(Quarantine.value(agent: "Lodge", at: Date())))
        #expect(!Provenance.isOwnMark(nil))
        #expect(!Provenance.isOwnMark("0081;00000010;Lodge;"))
        #expect(!Provenance.isOwnMark("0083;00000010;WebKit;"))
        #expect(!Provenance.isOwnMark("0083;00000010;Lodge;1234-ABCD"))
        #expect(!Provenance.isOwnMark("0083;0000zz10;Lodge;"))
        #expect(!Provenance.isOwnMark("0083;;Lodge;"))
        #expect(!Provenance.isOwnMark("0083;00000010;Lodge"))
    }

    @Test func removeWhereFromsKeepsTheMarkAndToleratesNone() throws {
        defer { cleanUp() }
        let path = file.path(percentEncoded: false)
        let whereFroms = Array("https://secret.example/file.zip".utf8)
        #expect(setxattr(path, Provenance.whereFromsAttribute, whereFroms, whereFroms.count, 0, 0) == 0)
        let mark = Array("0081;00000001;Safari;".utf8)
        #expect(setxattr(path, Quarantine.attribute, mark, mark.count, 0, 0) == 0)
        try Provenance.removeWhereFroms(file)
        #expect(getxattr(path, Provenance.whereFromsAttribute, nil, 0, 0, 0) < 0)
        #expect(Quarantine.read(file) == "0081;00000001;Safari;")
        try Provenance.removeWhereFroms(file)
    }

    @Test func removeWhereFromsOnAMissingFileThrows() {
        #expect(throws: POSIXError.self) {
            try Provenance.removeWhereFroms(file.appendingPathExtension("missing"))
        }
        cleanUp()
    }
}
