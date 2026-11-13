#if os(iOS)
import Foundation

private let echoWidgetDarwinName = "com.motrolrea.echomusic.widget.command" as CFString
private let echoWidgetSuite = "group.com.motrolrea.echomusic"

private func echoWidgetDarwinCallback(
    _ center: CFNotificationCenter?,
    _ observer: UnsafeMutableRawPointer?,
    _ name: CFNotificationName?,
    _ object: UnsafeRawPointer?,
    _ userInfo: CFDictionary?
) {
    Task { @MainActor in
        EchoWidgetCommands.consumePending()
    }
}

/// Widget buttons write a command into the App Group and tap the running
/// player with a Darwin notification. The intent itself cannot see AVPlayer.
@MainActor
public enum EchoWidgetCommands {
    private static var started = false
    private static var lastCommand = ""
    private static var lastAt = Date.distantPast

    public static func start() {
        guard !started else { return }
        started = true
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            nil,
            echoWidgetDarwinCallback,
            echoWidgetDarwinName,
            nil,
            .deliverImmediately
        )
        consumePending()
    }

    @discardableResult
    public static func handle(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "moumusic" else { return false }
        let host = url.host?.lowercased() ?? ""
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        switch host {
        case "toggle":
            let play = items?.first { $0.name == "play" }?.value
            if play == "1" { perform("play") }
            else if play == "0" { perform("pause") }
            else { perform("toggle") }
        case "next":
            perform("next")
        case "previous":
            perform("previous")
        case "play":
            if let raw = items?.first(where: { $0.name == "index" })?.value, let index = Int(raw) {
                perform("play:\(index)")
            }
        case "nowplaying":
            break
        default:
            return false
        }
        return true
    }

    public static func perform(_ command: String) {
        let now = Date()
        if command == lastCommand, now.timeIntervalSince(lastAt) < 0.35 { return }
        lastCommand = command
        lastAt = now
        let player = PlayerService.shared
        switch command {
        case "play":
            if player.isPlaying {
                break
            } else if player.currentTrack == nil {
                if !player.resumeLastPlayback() { player.togglePlayPause() }
            } else {
                player.togglePlayPause()
            }
        case "pause":
            if player.isPlaying { player.togglePlayPause() }
        case "toggle":
            if player.currentTrack == nil {
                if !player.resumeLastPlayback() { player.togglePlayPause() }
            } else {
                player.togglePlayPause()
            }
        case "next":
            player.next()
        case "previous":
            player.previous()
        default:
            if command.hasPrefix("play:") {
                let index = Int(command.dropFirst(5)) ?? -1
                if index < 0 { player.next() } else { player.playQueueIndex(index) }
            }
        }
        player.publishWidgetSnapshot()
    }

    static func consumePending() {
        let defaults = UserDefaults(suiteName: echoWidgetSuite)
        var command = defaults?.string(forKey: "echo.widget.command")
        var stamp = defaults?.double(forKey: "echo.widget.commandAt") ?? 0
        if let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: echoWidgetSuite) {
            let file = container.appendingPathComponent("echo-widget-command.txt")
            if let text = try? String(contentsOf: file, encoding: .utf8) {
                let age = Date().timeIntervalSince((try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast)
                if age < 30, command == nil || stamp == 0 {
                    command = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    stamp = Date().timeIntervalSince1970
                }
                try? FileManager.default.removeItem(at: file)
            }
        }
        defaults?.removeObject(forKey: "echo.widget.command")
        defaults?.removeObject(forKey: "echo.widget.commandAt")
        guard let command, !command.isEmpty, Date().timeIntervalSince1970 - stamp < 30 else { return }
        perform(command)
    }
}
#endif
