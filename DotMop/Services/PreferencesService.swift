import AppKit
import Observation
import SwiftUI

enum AppLanguage: String, CaseIterable, Codable {
    case system, simplifiedChinese, english

    var title: LocalizedStringKey {
        switch self {
        case .system: "系统默认"
        case .simplifiedChinese: "简体中文"
        case .english: "English"
        }
    }

    func resolved(in preferred: [String] = Locale.preferredLanguages) -> Self {
        guard self == .system else { return self }
        for identifier in preferred {
            switch Locale(identifier: identifier).language.languageCode?.identifier {
            case "zh": return .simplifiedChinese
            case "en": return .english
            default: continue
            }
        }
        return .simplifiedChinese
    }

    var locale: Locale {
        Locale(identifier: resolved() == .english ? "en" : "zh-Hans")
    }
}

enum AppAppearance: String, CaseIterable, Codable {
    case system, light, dark

    var title: LocalizedStringKey {
        switch self {
        case .system: "跟随系统"
        case .light: "浅色"
        case .dark: "深色"
        }
    }

    var nativeAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

struct Preferences: Codable, Equatable {
    struct Cleanup: Codable, Equatable {
        var automatic = false
        var requiresConfirmation = true
    }

    var showMenuBar = true
    var keepRunning = true
    var language: AppLanguage = .simplifiedChinese
    var appearance: AppAppearance = .system
    var autoScanOnOpen = true
    var autoScanOnMount = true
    var scanDSStore = true
    var scanAppleDouble = true
    var selectDSStore = true
    var selectAppleDouble = false
    var acknowledgedAppleDouble = false
    var dismissedLoginPrompt = false
    private var savedCleanup: Cleanup?
    private var savedIncrementalScan: Bool?

    var incrementalScan: Bool {
        get { savedIncrementalScan ?? true }
        set { savedIncrementalScan = newValue }
    }

    var cleanup: Cleanup {
        get { savedCleanup ?? Cleanup() }
        set { savedCleanup = newValue }
    }

    func selectsByDefault(_ kind: FileKind) -> Bool {
        switch kind {
        case .dsStore: scanDSStore && selectDSStore
        case .appleDouble: scanAppleDouble && selectAppleDouble && acknowledgedAppleDouble
        }
    }
}

@MainActor
@Observable
final class PreferencesStore {
    @ObservationIgnored private let defaults: UserDefaults
    private static let key = "preferences.v1"

    var value: Preferences {
        didSet {
            if let data = try? JSONEncoder().encode(value) {
                defaults.set(data, forKey: Self.key)
            }
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        value = defaults.data(forKey: Self.key)
            .flatMap { try? JSONDecoder().decode(Preferences.self, from: $0) } ?? Preferences()
    }
}

enum L10n {
    static func text(_ key: String, language: AppLanguage) -> String {
        let identifier = language.locale.identifier
        guard let url = Bundle.main.url(forResource: identifier, withExtension: "lproj"),
              let bundle = Bundle(url: url) else { return key }
        return bundle.localizedString(forKey: key, value: key, table: nil)
    }
}
