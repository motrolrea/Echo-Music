#if os(iOS)
import CoreText
import Foundation
import SwiftUI
import UniformTypeIdentifiers
import UIKit

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

/// 字体文件选择器。用 sheet 打开系统文件选择器，避免和其他 fileImporter 叠加后无法弹出。
struct FontDocumentPicker: UIViewControllerRepresentable {
    let onPick: (URL) -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick, onCancel: onCancel)
    }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        var types: [UTType] = [.font]
        if let ttf = UTType(filenameExtension: "ttf") { types.append(ttf) }
        if let otf = UTType(filenameExtension: "otf") { types.append(otf) }
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: true)
        picker.allowsMultipleSelection = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        private let onPick: (URL) -> Void
        private let onCancel: () -> Void

        init(onPick: @escaping (URL) -> Void, onCancel: @escaping () -> Void) {
            self.onPick = onPick
            self.onCancel = onCancel
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else {
                onCancel()
                return
            }
            onPick(url)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onCancel()
        }
    }
}
#endif
