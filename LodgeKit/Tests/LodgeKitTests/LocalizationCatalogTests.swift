import Foundation
import Testing

@testable import LodgeKit

@Suite struct LocalizationCatalogTests {
    private static let repo = URL(filePath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    static let catalogs = [
        "LodgeKit/Sources/LodgeKit/Resources/Localizable.xcstrings",
        "Lodge/Localizable.xcstrings",
    ]

    @Test(arguments: catalogs)
    func everyEntryHasATranslatedChineseValue(_ path: String) throws {
        let data = try Data(contentsOf: Self.repo.appending(path: path))
        let catalog = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(catalog["sourceLanguage"] as? String == "en")
        let strings = try #require(catalog["strings"] as? [String: [String: Any]])
        #expect(!strings.isEmpty)
        for (key, entry) in strings {
            let localizations = entry["localizations"] as? [String: Any]
            let unit = (localizations?["zh-Hant"] as? [String: Any])?["stringUnit"] as? [String: Any]
            #expect(unit?["state"] as? String == "translated", "\(key)")
            #expect((unit?["value"] as? String)?.isEmpty == false, "\(key)")
        }
    }

    /// Every `String(localized:)` literal in LodgeKit's sources has a catalog entry, placeholders compared as `%`.
    @Test func everyLocalizedSourceStringHasACatalogEntry() throws {
        let data = try Data(contentsOf: Self.repo.appending(path: Self.catalogs[0]))
        let catalog = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let strings = try #require(catalog["strings"] as? [String: Any])
        let keys = Set(strings.keys.map { $0.replacing(/%(\d+\$)?(lld|@)/, with: "%") })
        let sources = Self.repo.appending(path: "LodgeKit/Sources/LodgeKit")
        let files = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        var found = 0
        for case let file as URL in files where file.pathExtension == "swift" {
            let text = try String(contentsOf: file, encoding: .utf8)
            for match in text.matches(of: /String\(\s*localized:\s*"((?:[^"\\]|\\.)*)"/) {
                let key = String(match.output.1).replacing(/\\\((?:[^()]|\([^()]*\))*\)/, with: "%")
                found += 1
                #expect(keys.contains(key), "\(file.lastPathComponent): \(key)")
            }
        }
        #expect(found > 2)
    }

    @Test func moduleBundleResolvesChinese() throws {
        let path = try #require(Bundle.module.path(forResource: "zh-Hant", ofType: "lproj"))
        let bundle = try #require(Bundle(path: path))
        #expect(bundle.localizedString(forKey: "Signed in and remembered", value: nil, table: nil) == "保留登入與紀錄")
    }

    @Test func chineseFormatStringsTakeTheirArguments() throws {
        let path = try #require(Bundle.module.path(forResource: "zh-Hant", ofType: "lproj"))
        let bundle = try #require(Bundle(path: path))
        func format(_ key: String, _ arguments: any CVarArg...) -> String {
            String(format: bundle.localizedString(forKey: key, value: nil, table: nil), arguments: arguments)
        }
        #expect(format("Workspace %lld", 3) == "工作空間 3")
        #expect(format("%@ of %@", "1 MB", "5 MB") == "1 MB，共 5 MB")
        #expect(format("Use %lld characters or fewer.", 40) == "名稱不得超過 40 個字元。")
    }

    @Test func englishStaysTheSource() {
        #expect(ShortcutCatalog[.newTab].title == "New Tab")
        #expect(ShortcutMenu.help.title == "Help")
        #expect(DialogGate.title(for: Origin(scheme: "https", host: "a.com", port: 0)) == "https://a.com says")
    }
}
