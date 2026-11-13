import Foundation
import Testing
import UniformTypeIdentifiers

@testable import LodgeKit

@Suite struct DownloadOpenRiskTests {
    @Test(arguments: [
        "a.command", "a.tool", "a.sh", "A.APP", "a.pkg", "a.mpkg", "a.dmg", "a.terminal", "a.scpt", "a.workflow",
        "a.py", "a.zsh", "a.fileloc", "a.webloc", "a.inetloc", "a.jar", "a.scptd", "a.applescript", "a.action",
        "a.prefPane", "a.saver", "a.kext", "a.plugin", "a.bundle",
    ])
    func appsScriptsAndInstallersAsk(_ name: String) {
        #expect(DownloadOpenRisk.isAppOrScript(fileName: name))
    }

    @Test(arguments: ["a.pdf", "a.zip", "a.png", "a.txt", "README", ".env"])
    func documentsOpenDirectly(_ name: String) {
        #expect(!DownloadOpenRisk.isAppOrScript(fileName: name))
    }

    @Test func theFilesTypeCountsWhateverItsName() {
        #expect(DownloadOpenRisk.isAppOrScript(fileName: "tool", contentType: .unixExecutable))
        #expect(DownloadOpenRisk.isAppOrScript(fileName: "a.txt", contentType: .applicationBundle))
        #expect(!DownloadOpenRisk.isAppOrScript(fileName: "a", contentType: .plainText))
    }

    @Test func theConfirmationNamesTheFile() {
        #expect(DownloadOpenRisk.confirmation(for: "x.app") == "“x.app” is an app or script. Open it anyway?")
    }
}
