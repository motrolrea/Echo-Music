#if os(iOS)
import CoreText
import Foundation
import SwiftUI

/// 用户导入的第三方字体。只作用于界面文字，不改系统控件自己的字重。
@MainActor
final class AppFontStore {
    static let shared = AppFontStore()

    private let fileName = "custom-font.dat"

    private init() {
        registerSavedFont()
    }

    func install(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url),
              let provider = CGDataProvider(data: data as CFData),
              let cgFont = CGFont(provider),
              let name = cgFont.postScriptName as String? else { return nil }
        do {
            try data.write(to: fontURL, options: .atomic)
        } catch {
            return nil
        }
        CTFontManagerRegisterGraphicsFont(cgFont, nil)
        UserDefaults.standard.set(name, forKey: AppAppearanceKeys.customFont)
        apply(name)
        return name
    }

    func clear() {
        UserDefaults.standard.removeObject(forKey: AppAppearanceKeys.customFont)
        try? FileManager.default.removeItem(at: fontURL)
        apply(nil)
    }

    private func registerSavedFont() {
        guard let data = try? Data(contentsOf: fontURL),
              let provider = CGDataProvider(data: data as CFData),
              let cgFont = CGFont(provider) else { return }
        CTFontManagerRegisterGraphicsFont(cgFont, nil)
        if let name = UserDefaults.standard.string(forKey: AppAppearanceKeys.customFont) {
            apply(name)
        }
    }

    private func apply(_ name: String?) {
        NotificationCenter.default.post(name: .echoCustomFontDidChange, object: name)
    }

    private var fontURL: URL {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(fileName)
    }
}

extension Notification.Name {
    static let echoCustomFontDidChange = Notification.Name("echoCustomFontDidChange")
}

struct EchoCustomFontModifier: ViewModifier {
    @AppStorage(AppAppearanceKeys.customFont) private var fontName = ""

    func body(content: Content) -> some View {
        content.font(fontName.isEmpty ? nil : .custom(fontName, size: 17))
    }
}
#endif
