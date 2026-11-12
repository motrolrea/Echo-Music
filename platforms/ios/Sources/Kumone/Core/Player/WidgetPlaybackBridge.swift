import Foundation
#if os(iOS)
import WidgetKit
#endif

struct WidgetQueueItem: Codable {
    let title: String
    let artist: String
    let index: Int
    let current: Bool
}

enum WidgetPlaybackBridge {
    static let suiteName = "group.com.jiajia2222.moumusic"
    private static let coverName = "echo-widget-cover.jpg"

    /// Writes the desktop-widget snapshot into the shared App Group.
    static func publish(title: String, artist: String, playing: Bool, coverURL: String? = nil,
                        elapsed: Double? = nil, duration: Double? = nil,
                        queue: [WidgetQueueItem] = []) {
        guard let defaults = UserDefaults(suiteName: suiteName) else { return }
        defaults.set(title, forKey: "echo.widget.title")
        defaults.set(artist, forKey: "echo.widget.artist")
        defaults.set(playing, forKey: "echo.widget.playing")
        if let coverURL { defaults.set(coverURL, forKey: "echo.widget.coverURL") }
        if let elapsed { defaults.set(elapsed, forKey: "echo.widget.elapsed") }
        if let duration { defaults.set(duration, forKey: "echo.widget.duration") }
        if let data = try? JSONEncoder().encode(queue) {
            defaults.set(data, forKey: "echo.widget.queue")
        }
        #if os(iOS)
        DispatchQueue.main.async {
            WidgetCenter.shared.reloadAllTimelines()
        }
        #endif
    }

    static func publishCover(_ data: Data?) {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: suiteName
        ) else { return }
        let file = container.appendingPathComponent(coverName)
        if let data, !data.isEmpty {
            try? data.write(to: file, options: .atomic)
        } else {
            try? FileManager.default.removeItem(at: file)
        }
        #if os(iOS)
        DispatchQueue.main.async {
            WidgetCenter.shared.reloadAllTimelines()
        }
        #endif
    }

    static func coverFileURL() -> URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: suiteName)?
            .appendingPathComponent(coverName)
    }

    static func storeCover(from url: URL) async {
        guard let (data, response) = try? await URLSession.shared.data(from: url),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              !data.isEmpty else { return }
        publishCover(data)
    }
}
