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

struct WidgetSnapshot: Codable {
    var title: String
    var artist: String
    var playing: Bool
    var coverURL: String?
    var elapsed: Double
    var duration: Double
    var queue: [WidgetQueueItem]
    var updatedAt: Date
}

enum WidgetPlaybackBridge {
    static let suiteName = "group.com.motrolrea.echomusic"
    private static let coverName = "echo-widget-cover.jpg"
    private static let snapshotName = "echo-widget-snapshot.json"

    /// Writes the widget snapshot. Unsigned builds have no App Group, so the
    /// same file is also stored where the embedded widget can open it directly.
    static func publish(title: String, artist: String, playing: Bool, coverURL: String? = nil,
                        elapsed: Double? = nil, duration: Double? = nil,
                        queue: [WidgetQueueItem] = []) {
        let snapshot = WidgetSnapshot(
            title: title,
            artist: artist,
            playing: playing,
            coverURL: coverURL,
            elapsed: elapsed ?? 0,
            duration: duration ?? 0,
            queue: Array(queue.prefix(7)),
            updatedAt: Date()
        )
        if let defaults = UserDefaults(suiteName: suiteName) {
            defaults.set(snapshot.title, forKey: "echo.widget.title")
            defaults.set(snapshot.artist, forKey: "echo.widget.artist")
            defaults.set(snapshot.playing, forKey: "echo.widget.playing")
            if let coverURL { defaults.set(coverURL, forKey: "echo.widget.coverURL") }
            defaults.set(snapshot.elapsed, forKey: "echo.widget.elapsed")
            defaults.set(snapshot.duration, forKey: "echo.widget.duration")
            if let data = try? JSONEncoder().encode(snapshot.queue) {
                defaults.set(data, forKey: "echo.widget.queue")
            }
        }
        if let data = try? JSONEncoder().encode(snapshot), let url = fileURL(snapshotName) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
        reload()
    }

    static func publishCover(_ data: Data?) {
        guard let file = fileURL(coverName) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data, !data.isEmpty {
            try? data.write(to: file, options: .atomic)
        } else {
            try? FileManager.default.removeItem(at: file)
        }
        reload()
    }

    static func currentSnapshot() -> WidgetSnapshot? {
        guard let url = fileURL(snapshotName),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(WidgetSnapshot.self, from: data)
    }

    static func coverFileURL() -> URL? {
        fileURL(coverName)
    }

    static func storeCover(from url: URL) async {
        guard let (data, response) = try? await URLSession.shared.data(from: url),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              !data.isEmpty else { return }
        publishCover(data)
    }

    private static func reload() {
        #if os(iOS)
        DispatchQueue.main.async {
            WidgetCenter.shared.reloadTimelines(ofKind: "EchoNowPlaying")
            WidgetCenter.shared.reloadTimelines(ofKind: "EchoOpenPlayer")
        }
        #endif
    }

    private static func fileURL(_ name: String) -> URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: suiteName)?
            .appendingPathComponent(name)
    }
}
