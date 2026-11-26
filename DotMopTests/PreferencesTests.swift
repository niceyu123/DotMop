import XCTest
@testable import DotMop

final class PreferencesTests: XCTestCase {
    @MainActor
    func testSafeDefaultsAndPersistence() throws {
        let name = "DotMopTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }

        let store = PreferencesStore(defaults: defaults)
        XCTAssertTrue(store.value.autoScanOnOpen)
        XCTAssertTrue(store.value.autoScanOnMount)
        XCTAssertTrue(store.value.selectDSStore)
        XCTAssertFalse(store.value.selectAppleDouble)
        XCTAssertFalse(store.value.cleanup.automatic)
        XCTAssertTrue(store.value.cleanup.requiresConfirmation)
        XCTAssertTrue(store.value.showMenuBar)
        XCTAssertTrue(store.value.keepRunning)
        XCTAssertEqual(store.value.language, .simplifiedChinese)

        store.value.language = .english
        store.value.appearance = .dark
        store.value.selectDSStore = false
        store.value.cleanup.automatic = true
        store.value.cleanup.requiresConfirmation = false
        let restored = PreferencesStore(defaults: defaults)
        XCTAssertEqual(restored.value.language, .english)
        XCTAssertEqual(restored.value.appearance, .dark)
        XCTAssertFalse(restored.value.selectDSStore)
        XCTAssertTrue(restored.value.cleanup.automatic)
        XCTAssertFalse(restored.value.cleanup.requiresConfirmation)
    }

    @MainActor
    func testLegacyPreferencesKeepExistingValuesAndUseSafeCleanupDefaults() throws {
        let name = "DotMopTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let legacy = """
        {"showMenuBar":false,"keepRunning":false,"language":"english","appearance":"dark",
         "autoScanOnOpen":false,"autoScanOnMount":true,"scanDSStore":true,"scanAppleDouble":true,
         "selectDSStore":false,"selectAppleDouble":true,"acknowledgedAppleDouble":true,"dismissedLoginPrompt":true}
        """
        defaults.set(Data(legacy.utf8), forKey: "preferences.v1")
        let value = PreferencesStore(defaults: defaults).value
        XCTAssertEqual(value.language, .english)
        XCTAssertFalse(value.autoScanOnOpen)
        XCTAssertTrue(value.selectsByDefault(.appleDouble))
        XCTAssertFalse(value.cleanup.automatic)
        XCTAssertTrue(value.cleanup.requiresConfirmation)
    }

    func testSystemLanguageAndLocalizations() {
        XCTAssertEqual(AppLanguage.system.resolved(in: ["fr-FR", "en-GB"]), .english)
        XCTAssertEqual(AppLanguage.system.resolved(in: ["zh-Hant-TW", "en"]), .simplifiedChinese)
        XCTAssertEqual(AppLanguage.system.resolved(in: ["fr-FR"]), .simplifiedChinese)
        XCTAssertEqual(L10n.text("移动磁盘隐藏文件清理", language: .english), "Hidden File Cleaner for External Drives")
        XCTAssertEqual(L10n.text("移动磁盘隐藏文件清理", language: .simplifiedChinese), "移动磁盘隐藏文件清理")
    }
}
