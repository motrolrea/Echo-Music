import Foundation
#if os(iOS)
import WidgetKit
#endif

enum WidgetPlaybackBridge {
    static let suiteName = "group.com.jiajia2222.moumusic"

    /// Writes the desktop-widget snapshot. Unsigned builds have no App Group,
    /// so a missing suite leaves the widget on its placeholder.
    static func publish(title: String, artist: String, playing: Bool) {
        guard let defaults = UserDefaults(suiteName: suiteName) else { return }
        defaults.set(title, forKey: "echo.widget.title")
        defaults.set(artist, forKey: "echo.widget.artist")
        defaults.set(playing, forKey: "echo.widget.playing")
        #if os(iOS)
        DispatchQueue.main.async {
            WidgetCenter.shared.reloadAllTimelines()
        }
        #endif
    }
}
