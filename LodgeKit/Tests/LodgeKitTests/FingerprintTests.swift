import Foundation
import Testing

@testable import LodgeKit

@Suite struct FingerprintTests {
    private let work = Workspace(name: "Work", symbol: "briefcase")

    private func snapshot(_ entries: [SessionSnapshot.WorkspaceSnapshot]) -> SessionSnapshot {
        SessionSnapshot(
            workspaces: entries, windows: [.init(activeWorkspace: Workspace.defaultID)], pendingDeletions: [])
    }

    private func roundTrip(_ snapshot: SessionSnapshot) throws -> SessionSnapshot {
        try SessionSnapshot.decode(snapshot.encoded())
    }

    /// The session file with every workspace's `fingerprint` replaced by `value` (nil: removed).
    private func rewritingFingerprints(_ snapshot: SessionSnapshot, to value: Any?) throws -> Data {
        var json = try #require(JSONSerialization.jsonObject(with: snapshot.encoded()) as? [String: Any])
        let workspaces = try #require(json["workspaces"] as? [[String: Any]])
        json["workspaces"] = workspaces.map { entry in
            var entry = entry
            entry["fingerprint"] = value
            return entry
        }
        return try JSONSerialization.data(withJSONObject: json)
    }

    // MARK: Seed

    @Test func sameKeyAndSiteGiveTheSameSeed() {
        let settings = FingerprintSettings.fresh()
        #expect(settings.seed(for: "example.com") == settings.seed(for: "example.com"))
        #expect(FingerprintSettings(key: settings.key).seed(for: "example.com") == settings.seed(for: "example.com"))
    }

    @Test func differentKeyOrSiteGiveDifferentSeeds() {
        let one = FingerprintSettings.fresh()
        let other = FingerprintSettings.fresh()
        #expect(one.key != other.key)
        #expect(one.seed(for: "example.com") != other.seed(for: "example.com"))
        #expect(one.seed(for: "example.com") != one.seed(for: "example.org"))
    }

    @Test func seedIsHexOfHMACSHA256() {
        // RFC 4231 test case 2 uses a short key; the HMAC is the same for any key length, so it checks the encoding.
        let settings = FingerprintSettings(key: Data("Jefe".utf8))
        #expect(
            settings.seed(for: "what do ya want for nothing?")
                == "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843")
    }

    @Test func freshKeyIs32Bytes() {
        #expect(FingerprintSettings.fresh().key.count == 32)
        #expect(FingerprintSettings.fresh().offSites.isEmpty)
    }

    // MARK: Exceptions

    @Test func setOffTurnsASiteOffAndBackOn() {
        var settings = FingerprintSettings.fresh()
        settings.setOff(true, "example.com")
        #expect(settings.isOff("example.com"))
        #expect(!settings.isOff("example.org"))
        settings.setOff(false, "example.com")
        #expect(!settings.isOff("example.com"))
    }

    // MARK: Session file

    @Test func keyAndExceptionsSurviveEncodeDecodePerWorkspace() throws {
        var defaults = FingerprintSettings.fresh()
        defaults.setOff(true, "bank.example")
        var custom = FingerprintSettings.fresh()
        custom.setOff(true, "maps.example")
        let snapshot = snapshot([
            .init(workspace: .default, content: .empty, fingerprint: defaults),
            .init(workspace: work, content: .empty, fingerprint: custom),
        ])
        let decoded = try roundTrip(snapshot)
        #expect(decoded == snapshot)
        let byID = Dictionary(uniqueKeysWithValues: decoded.workspaces.map { ($0.workspace.id, $0.fingerprint) })
        #expect(byID[Workspace.defaultID] == defaults)
        #expect(byID[work.id] == custom)
        #expect(byID[Workspace.defaultID]??.isOff("maps.example") == false)
    }

    @Test func defaultAndCustomWorkspacesCarryOneAnonymousNever() throws {
        let snapshot = snapshot([
            .init(workspace: .default, content: .empty), .init(workspace: work, content: .empty),
            .init(workspace: .anonymous, content: .empty, fingerprint: .fresh()),
        ])
        #expect(snapshot.workspaces.map { $0.fingerprint != nil } == [true, true, false])
        #expect(Set(snapshot.workspaces.compactMap(\.fingerprint?.key)).count == 2)
        let json = try #require(JSONSerialization.jsonObject(with: snapshot.encoded()) as? [String: Any])
        let workspaces = try #require(json["workspaces"] as? [[String: Any]])
        #expect(workspaces.map { $0["fingerprint"] != nil } == [true, true, false])
    }

    @Test func anonymousReadFromAFileStillHasNone() throws {
        let saved = snapshot([.init(workspace: .default, content: .empty)])
        let data = try rewritingFingerprints(saved, to: ["key": Data(count: 32).base64EncodedString()])
        let decoded = try SessionSnapshot.decode(data)
        #expect(decoded.workspaces.last?.workspace.kind == .anonymous)
        #expect(decoded.workspaces.last?.fingerprint == nil)
    }

    @Test func oldFileWithoutAKeyLoadsAndGainsOne() throws {
        let saved = snapshot([.init(workspace: .default, content: .empty), .init(workspace: work, content: .empty)])
        let decoded = try SessionSnapshot.decode(rewritingFingerprints(saved, to: nil))
        #expect(decoded.version == SessionSnapshot.currentVersion)
        #expect(decoded.workspaces.map(\.fingerprint?.key.count) == [32, 32, nil])
        let reread = try roundTrip(decoded)
        #expect(reread.workspaces.map(\.fingerprint) == decoded.workspaces.map(\.fingerprint))
    }

    @Test(arguments: [16, 31, 33, 0])
    func badLengthKeyReadsAsFresh(length: Int) throws {
        let saved = snapshot([.init(workspace: .default, content: .empty)])
        let bad = Data(repeating: 7, count: length)
        let data = try rewritingFingerprints(
            saved, to: ["key": bad.base64EncodedString(), "offSites": ["bank.example"]])
        let decoded = try SessionSnapshot.decode(data)
        let fingerprint = try #require(decoded.workspaces.first?.fingerprint)
        #expect(fingerprint.key.count == 32)
        #expect(fingerprint.key != bad)
        #expect(fingerprint.offSites.isEmpty)
    }

    @Test func malformedFingerprintReadsAsFresh() throws {
        let saved = snapshot([.init(workspace: .default, content: .empty)])
        let decoded = try SessionSnapshot.decode(rewritingFingerprints(saved, to: "not settings"))
        #expect(decoded.workspaces.first?.fingerprint?.key.count == 32)
    }

    @Test func malformedOffSitesKeepTheKey() throws {
        let key = FingerprintSettings.fresh().key
        let saved = snapshot([.init(workspace: .default, content: .empty)])
        let data = try rewritingFingerprints(saved, to: ["key": key.base64EncodedString(), "offSites": 3])
        let decoded = try SessionSnapshot.decode(data)
        #expect(decoded.workspaces.first?.fingerprint == FingerprintSettings(key: key))
    }

    // MARK: Keys per workspace

    /// What the coordinator's `snapshot` builds: every workspace with its key from `keys`.
    private func snapshot(_ list: WorkspaceList, _ keys: FingerprintKeys) -> SessionSnapshot {
        snapshot(list.workspaces.map { .init(workspace: $0, content: .empty, fingerprint: keys[$0.id]) })
    }

    @Test func defaultOnAFirstLaunchKeepsOneKeyAcrossSnapshots() {
        let list = WorkspaceList()
        let keys = FingerprintKeys(list.workspaces)
        #expect(keys[Workspace.defaultID] != nil)
        #expect(keys[Workspace.anonymousID] == nil)
        #expect(snapshot(list, keys) == snapshot(list, keys))
        #expect(snapshot(list, keys).workspaces.first?.fingerprint == keys[Workspace.defaultID])
    }

    @Test func aCreatedWorkspaceKeepsOneKeyAcrossSnapshots() throws {
        var list = WorkspaceList()
        var keys = FingerprintKeys(list.workspaces)
        let created = try list.create(name: "Work", symbol: "briefcase")
        keys.add(created)
        let first = try #require(keys[created.id])
        keys.add(created)
        #expect(keys[created.id] == first)
        #expect(snapshot(list, keys) == snapshot(list, keys))
        #expect(snapshot(list, keys).workspaces.first { $0.workspace.id == created.id }?.fingerprint == first)
    }

    @Test func restoredKeysAreKeptAndMissingOnesFilled() {
        var restored = FingerprintSettings.fresh()
        restored.setOff(true, "bank.example")
        let keys = FingerprintKeys([.default, work, .anonymous], restored: [Workspace.defaultID: restored])
        #expect(keys[Workspace.defaultID] == restored)
        #expect(keys[work.id]?.key.count == 32)
        #expect(keys[Workspace.anonymousID] == nil)
    }

    @Test func anonymousNeverGetsOne() {
        var keys = FingerprintKeys([])
        keys.add(.anonymous, .fresh())
        #expect(keys[Workspace.anonymousID] == nil)
    }

    @Test func anExceptionIsKeptPerWorkspaceWithItsKey() throws {
        let list = WorkspaceList()
        var keys = FingerprintKeys([.default, work, .anonymous])
        let key = try #require(keys[Workspace.defaultID]?.key)
        keys.setOff(true, "bank.example", in: Workspace.defaultID)
        keys.setOff(true, "bank.example", in: Workspace.anonymousID)
        #expect(keys[Workspace.defaultID]?.isOff("bank.example") == true)
        #expect(keys[Workspace.defaultID]?.key == key)
        #expect(keys[work.id]?.isOff("bank.example") == false)
        #expect(keys[Workspace.anonymousID] == nil)
        #expect(snapshot(list, keys).workspaces.first?.fingerprint?.offSites == ["bank.example"])
        keys.setOff(false, "bank.example", in: Workspace.defaultID)
        #expect(keys[Workspace.defaultID]?.offSites.isEmpty == true)
        #expect(keys[Workspace.defaultID]?.key == key)
    }

    @Test func droppedWorkspaceForgetsItsKey() {
        var keys = FingerprintKeys([.default, work])
        keys.drop(work.id)
        #expect(keys[work.id] == nil)
        #expect(keys[Workspace.defaultID] != nil)
    }
    // MARK: Page seed and top site

    @Test func pageSeedIsTheSitesSeedUnlessExceptedOrAbsent() {
        var settings = FingerprintSettings.fresh()
        #expect(settings.pageSeed(for: "example.com") == settings.seed(for: "example.com"))
        #expect(settings.pageSeed(for: nil) == nil)
        settings.setOff(true, "example.com")
        #expect(settings.pageSeed(for: "example.com") == nil)
        #expect(settings.pageSeed(for: "other.com") == settings.seed(for: "other.com"))
    }

    @Test func topSiteIsTheRegistrableDomain() {
        let url = URL(string: "https://www.example.co.uk/a")
        #expect(FingerprintSite.of(url, inheriting: "opener.com") == "example.co.uk")
        #expect(FingerprintSite.of(URL(string: "https://a.github.io"), inheriting: nil) == "a.github.io")
    }

    @Test func blankOrMissingURLInheritsItsCreatorsSite() {
        #expect(FingerprintSite.of(nil, inheriting: "opener.com") == "opener.com")
        #expect(FingerprintSite.of(URL(string: "about:blank"), inheriting: "opener.com") == "opener.com")
        #expect(FingerprintSite.of(URL(string: "about:blank#x"), inheriting: "opener.com") == "opener.com")
        #expect(FingerprintSite.of(URL(string: "about:blank"), inheriting: nil) == nil)
    }

    @Test func urlsWithoutARegistrableDomainHaveNoSite() {
        for raw in ["about:srcdoc", "data:text/html,hi", "file:///tmp/a.html", "lodge://settings"] {
            #expect(FingerprintSite.of(URL(string: raw), inheriting: "opener.com") == nil, "\(raw)")
        }
    }
}
