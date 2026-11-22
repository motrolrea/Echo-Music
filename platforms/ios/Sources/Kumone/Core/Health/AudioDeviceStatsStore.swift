#if os(iOS)
import AVFoundation
import Foundation
import HealthKit

/// 系统当前音频输出。只能知道设备和声道，不知道左右耳或充电盒电量。
struct AudioRouteSnapshot {
    let name: String
    let detail: String

    static func current() -> AudioRouteSnapshot {
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
        guard let port = outputs.first else {
            return AudioRouteSnapshot(name: "没有外接音频设备", detail: "正在使用本机扬声器")
        }
        let channels = port.channels?.count ?? 0
        let stereo = channels >= 2 ? "立体声" : "单声道"
        return AudioRouteSnapshot(name: port.portName, detail: "\(port.portType.audioKind) · \(stereo)")
    }
}

private extension AVAudioSession.Port {
    var audioKind: String {
        switch self {
        case .bluetoothA2DP, .bluetoothLE, .bluetoothHFP: return "蓝牙"
        case .headphones: return "有线耳机"
        case .airPlay: return "隔空播放"
        case .builtInSpeaker: return "本机扬声器"
        case .builtInReceiver: return "听筒"
        default: return "音频输出"
        }
    }
}

/// 从健康 App 的「耳机音量」记录里按设备型号聚合佩戴时长。
/// 健康数据只在本机读取，不上传。
@MainActor
final class AudioDeviceStatsStore: ObservableObject {
    struct DailyPoint: Identifiable, Equatable {
        let date: Date
        let duration: TimeInterval
        var id: Date { date }
    }

    /// 某一天的平均音量。没有记录时为 nil。
    struct VolumePoint: Identifiable, Equatable {
        let date: Date
        let decibels: Double?
        var id: Date { date }
    }

    /// 一次连续佩戴。相邻记录间隔不超过 60 秒就合并。
    struct Session: Identifiable, Equatable {
        let id: String
        let device: String
        let start: Date
        let end: Date
        let duration: TimeInterval
        let decibels: Double?
    }

    struct Device: Identifiable {
        let id: String
        let name: String
        var rank: Int
        var duration: TimeInterval
        var share: Double
        var sessionCount: Int
        var averageSession: TimeInterval
        var longestSession: TimeInterval
        var dailyMax: TimeInterval
        var averagePerActiveDay: TimeInterval
        var averageDecibels: Double?
        var peakDecibels: Double?
        var loudDuration: TimeInterval
        var lastUsed: Date?
        var daysUsed: Int
        var peakPeriod: String
        var peakShare: Double
        var weekdayAverage: TimeInterval
        var weekendAverage: TimeInterval
        var longestStreak: Int
        var currentStreak: Int
        var loudEvents: Int
        var hourly: [TimeInterval]
        var loudBuckets: [TimeInterval]
        var daily: [DailyPoint]
        var volumeDaily: [VolumePoint]
        var sessions: [Session]
    }

    enum Range: String, CaseIterable, Identifiable {
        case week
        case month
        case all

        var id: String { rawValue }

        var title: String {
            switch self {
            case .week: return "近 7 天"
            case .month: return "近 30 天"
            case .all: return "累计"
            }
        }

        var startDate: Date? {
            switch self {
            case .week: return Calendar.current.date(byAdding: .day, value: -7, to: Date())
            case .month: return Calendar.current.date(byAdding: .day, value: -30, to: Date())
            case .all: return nil
            }
        }
    }

    @Published private(set) var devices: [Device] = []
    @Published private(set) var totalDuration: TimeInterval = 0
    @Published private(set) var loudEvents = 0
    @Published private(set) var daily: [DailyPoint] = []
    @Published private(set) var hourly: [TimeInterval] = Array(repeating: 0, count: 24)
    @Published private(set) var loudBuckets: [TimeInterval] = Array(repeating: 0, count: 4)
    @Published private(set) var previousDuration: TimeInterval = 0
    @Published private(set) var loudDuration: TimeInterval = 0
    @Published private(set) var averageDecibels: Double?
    @Published private(set) var peakDecibels: Double?
    @Published private(set) var volumeDaily: [VolumePoint] = []
    @Published private(set) var recentSessions: [Session] = []
    @Published private(set) var todayDuration: TimeInterval = 0
    @Published private(set) var todayTopDevice: String?
    @Published private(set) var todayTopDuration: TimeInterval = 0
    @Published private(set) var activeDays = 0
    @Published private(set) var dailyAverage: TimeInterval = 0
    @Published private(set) var longestSession: TimeInterval = 0
    @Published private(set) var longestDay: TimeInterval = 0
    @Published private(set) var currentStreak = 0
    @Published private(set) var longestStreak = 0
    @Published private(set) var statisticsStart: Date?
    @Published private(set) var lastLoadedAt: Date?
    @Published private(set) var sessionCount = 0
    @Published private(set) var isLoading = false
    @Published private(set) var isRequesting = false
    @Published private(set) var isAuthorized = false
    @Published var errorMessage: String?

    private let healthStore = HKHealthStore()

    static var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    private var exposureType: HKQuantityType? {
        HKObjectType.quantityType(forIdentifier: .headphoneAudioExposure)
    }

    private var readableTypes: Set<HKObjectType> {
        var types = Set<HKObjectType>()
        if let exposureType { types.insert(exposureType) }
        if let events = HKObjectType.categoryType(forIdentifier: .headphoneAudioExposureEvent) {
            types.insert(events)
        }
        return types
    }

    func requestAuthorization() async -> Bool {
        guard let exposureType else {
            errorMessage = "这台设备不支持耳机音量数据"
            return false
        }
        isRequesting = true
        defer { isRequesting = false }
        let outcome: Result<Bool, Error> = await withCheckedContinuation { continuation in
            healthStore.requestAuthorization(toShare: [], read: readableTypes) { success, error in
                if let error {
                    continuation.resume(returning: .failure(error))
                } else {
                    continuation.resume(returning: .success(success))
                }
            }
        }
        switch outcome {
        case .failure(let error):
            isAuthorized = false
            errorMessage = "系统没有受理健康权限：\(error.localizedDescription)。全能签重签时必须保留 HealthKit，否则这个请求不会弹窗。"
            return false
        case .success(let success):
            isAuthorized = success
            if !success {
                errorMessage = "系统拒绝了健康数据请求。请到「设置 → 隐私与安全性 → 健康」允许读取耳机音量；如果那里没有本应用，就是重签时 HealthKit 被去掉了。"
            }
            return success
        }
    }

    func load(range: Range) async {
        guard let exposureType else {
            errorMessage = "这台设备不支持耳机音量数据"
            return
        }
        isLoading = true
        defer { isLoading = false }

        if !isAuthorized {
            guard await requestAuthorization() else { return }
        }

        let samples = await fetchSamples(exposureType, from: range.startDate, to: Date())

        let eventCounts = await loudEventCounts(range: range)
        loudEvents = eventCounts.values.reduce(0, +)

        if samples.isEmpty, loudEvents == 0 {
            resetStats()
            if errorMessage == nil {
                errorMessage = "请求已结束，但没有读到耳机音量。如果刚才没有弹出系统授权框，就是安装包里的 HealthKit 权限被重签去掉了。"
            }
            return
        }

        let buckets = groupedSlices(samples)

        // 重叠只算一次。间隔超过 60 秒就另算一次佩戴。
        var aggregated: [Device] = buckets.map { entry in
            let stats = Self.sessionStats(entry.value, device: entry.key)
            return Device(id: entry.key,
                          name: entry.key,
                          rank: 0,
                          duration: stats.duration,
                          share: 0,
                          sessionCount: stats.count,
                          averageSession: stats.average,
                          longestSession: stats.longest,
                          dailyMax: stats.dailyMap.values.max() ?? 0,
                          averagePerActiveDay: stats.daysUsed > 0
                              ? stats.duration / Double(stats.daysUsed) : 0,
                          averageDecibels: stats.averageDecibels,
                          peakDecibels: stats.peakDecibels,
                          loudDuration: stats.loudDuration,
                          lastUsed: stats.lastUsed,
                          daysUsed: stats.daysUsed,
                          peakPeriod: stats.peakPeriod,
                          peakShare: stats.peakShare,
                          weekdayAverage: stats.weekdayAverage,
                          weekendAverage: stats.weekendAverage,
                          longestStreak: stats.longestStreak,
                          currentStreak: stats.currentStreak,
                          loudEvents: eventCounts[entry.key, default: 0],
                          hourly: stats.hourly,
                          loudBuckets: stats.loudBuckets,
                          daily: Self.series(stats.dailyMap, range: range),
                          volumeDaily: Self.volumeSeries(Self.volumeMap(stats.sessions), range: range),
                          sessions: Array(stats.sessions.suffix(200)))
        }
        aggregated.sort { $0.duration > $1.duration }
        let total = aggregated.reduce(0) { $0 + $1.duration }
        devices = aggregated.enumerated().map { index, device in
            var copy = device
            copy.rank = index + 1
            copy.share = total > 0 ? device.duration / total : 0
            return copy
        }
        totalDuration = total

        let allSessions = devices.flatMap(\.sessions).sorted { $0.start > $1.start }
        recentSessions = Array(allSessions.prefix(60))

        let overall = Self.sessionStats(buckets.values.flatMap { $0 })
        daily = Self.series(overall.dailyMap, range: range)
        hourly = overall.hourly
        loudBuckets = overall.loudBuckets
        loudDuration = overall.loudDuration
        averageDecibels = overall.averageDecibels
        peakDecibels = overall.peakDecibels
        volumeDaily = Self.volumeSeries(Self.volumeMap(allSessions), range: range)
        activeDays = overall.dailyMap.count
        dailyAverage = activeDays > 0 ? total / Double(activeDays) : 0
        longestSession = overall.longest
        longestDay = overall.longestDay
        currentStreak = overall.currentStreak
        longestStreak = overall.longestStreak
        statisticsStart = buckets.values.flatMap { $0 }.map(\.start).min()
        lastLoadedAt = Date()
        sessionCount = overall.count
        computeToday(allSessions)
        previousDuration = await previousTotal(range: range)
        errorMessage = nil
    }

    private func resetStats() {
        devices = []
        daily = []
        hourly = Array(repeating: 0, count: 24)
        loudBuckets = Array(repeating: 0, count: 4)
        totalDuration = 0
        previousDuration = 0
        loudDuration = 0
        averageDecibels = nil
        peakDecibels = nil
        volumeDaily = []
        recentSessions = []
        todayDuration = 0
        todayTopDevice = nil
        todayTopDuration = 0
        activeDays = 0
        dailyAverage = 0
        longestSession = 0
        longestDay = 0
        currentStreak = 0
        longestStreak = 0
        statisticsStart = nil
        lastLoadedAt = nil
        sessionCount = 0
    }

    private func computeToday(_ sessions: [Session]) {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: Date())
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? Date()
        var byDevice: [String: TimeInterval] = [:]
        for session in sessions {
            let from = max(session.start, start)
            let to = min(session.end, end)
            let overlap = to.timeIntervalSince(from)
            if overlap > 0 { byDevice[session.device, default: 0] += overlap }
        }
        todayDuration = byDevice.values.reduce(0, +)
        if let top = byDevice.max(by: { $0.value < $1.value }) {
            todayTopDevice = top.key
            todayTopDuration = top.value
        } else {
            todayTopDevice = nil
            todayTopDuration = 0
        }
    }

    private func fetchSamples(_ type: HKQuantityType, from start: Date?, to end: Date) async -> [HKSample] {
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
        return await withCheckedContinuation { continuation in
            let query = HKSampleQuery(sampleType: type,
                                      predicate: predicate,
                                      limit: HKObjectQueryNoLimit,
                                      sortDescriptors: nil) { _, result, _ in
                continuation.resume(returning: result ?? [])
            }
            healthStore.execute(query)
        }
    }

    private func groupedSlices(_ samples: [HKSample]) -> [String: [ExposureSlice]] {
        var buckets: [String: [ExposureSlice]] = [:]
        for case let sample as HKQuantitySample in samples {
            let raw = (sample.device?.name ?? sample.device?.model)
                ?? (sample.metadata?[HKMetadataKeyDeviceName] as? String)
            let name = raw?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let name, !name.isEmpty else { continue }
            let host = ["iPhone", "iPad", "iPod", "Watch", "Apple TV", "Mac"]
            if host.contains(where: { name.localizedCaseInsensitiveContains($0) }) { continue }
            guard sample.endDate > sample.startDate else { continue }
            let decibels = sample.quantity.doubleValue(for: .decibelAWeightedSoundPressureLevel())
            buckets[name, default: []].append(
                ExposureSlice(start: sample.startDate, end: sample.endDate, decibels: decibels)
            )
        }
        return buckets
    }

    /// 上一个等长周期的总时长，用来和当前区间比较。
    private func previousTotal(range: Range) async -> TimeInterval {
        guard let exposureType, let start = range.startDate else { return 0 }
        let length = Date().timeIntervalSince(start)
        let samples = await fetchSamples(exposureType, from: start.addingTimeInterval(-length), to: start)
        guard !samples.isEmpty else { return 0 }
        return Self.sessionStats(groupedSlices(samples).values.flatMap { $0 }).duration
    }

    private static func dayCount(_ range: Range, earliest: Date?, today: Date) -> Int {
        let calendar = Calendar.current
        switch range {
        case .week:
            return 7
        case .month:
            return 30
        case .all:
            guard let earliest else { return 0 }
            let span = calendar.dateComponents([.day],
                                               from: calendar.startOfDay(for: earliest),
                                               to: today).day ?? 0
            return min(max(span + 1, 1), 30)
        }
    }

    private static func series(_ map: [Date: TimeInterval], range: Range) -> [DailyPoint] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let days = dayCount(range, earliest: map.keys.min(), today: today)
        return (0..<days).reversed().compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else { return nil }
            return DailyPoint(date: day, duration: map[day] ?? 0)
        }
    }

    private static func volumeMap(_ sessions: [Session]) -> [Date: (energy: Double, duration: TimeInterval)] {
        let calendar = Calendar.current
        var map: [Date: (energy: Double, duration: TimeInterval)] = [:]
        for session in sessions {
            guard let decibels = session.decibels, session.duration > 0 else { continue }
            let day = calendar.startOfDay(for: session.start)
            var entry = map[day, default: (0, 0)]
            entry.energy += pow(10, decibels / 10) * session.duration
            entry.duration += session.duration
            map[day] = entry
        }
        return map
    }

    private static func volumeSeries(_ map: [Date: (energy: Double, duration: TimeInterval)],
                                     range: Range) -> [VolumePoint] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let days = dayCount(range, earliest: map.keys.min(), today: today)
        return (0..<days).reversed().compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else { return nil }
            let entry = map[day]
            let decibels: Double?
            if let entry, entry.duration > 0, entry.energy > 0 {
                decibels = 10 * log10(entry.energy / entry.duration)
            } else {
                decibels = nil
            }
            return VolumePoint(date: day, decibels: decibels)
        }
    }

    private struct ExposureSlice {
        let start: Date
        let end: Date
        let decibels: Double
    }

    private struct SessionStats {
        let duration: TimeInterval
        let count: Int
        let average: TimeInterval
        let longest: TimeInterval
        let averageDecibels: Double?
        let peakDecibels: Double?
        let loudDuration: TimeInterval
        let lastUsed: Date?
        let daysUsed: Int
        let peakPeriod: String
        let peakShare: Double
        let weekdayAverage: TimeInterval
        let weekendAverage: TimeInterval
        let longestDay: TimeInterval
        let currentStreak: Int
        let longestStreak: Int
        let hourly: [TimeInterval]
        let loudBuckets: [TimeInterval]
        let dailyMap: [Date: TimeInterval]
        let sessions: [Session]
    }

    /// 先合并重叠，再按 60 秒空隙切开。音量按能量加权，不是把分贝直接平均。
    private static func sessionStats(_ slices: [ExposureSlice], device: String = "") -> SessionStats {
        let sorted = slices.sorted { $0.start < $1.start }
        var merged: [(start: Date, end: Date, energy: Double, duration: TimeInterval)] = []
        for slice in sorted {
            let length = slice.end.timeIntervalSince(slice.start)
            let energy = pow(10, slice.decibels / 10) * length
            if var current = merged.last, slice.start.timeIntervalSince(current.end) <= 60 {
                let overlap = max(0, current.end.timeIntervalSince(slice.start))
                current.end = max(current.end, slice.end)
                current.energy += energy * (length > 0 ? max(length - overlap, 0) / length : 0)
                current.duration += max(length - overlap, 0)
                merged[merged.count - 1] = current
            } else {
                merged.append((slice.start, slice.end, energy, length))
            }
        }
        let sessions = merged.compactMap { item -> Session? in
            guard item.duration > 0 else { return nil }
            let decibels = item.energy > 0 ? 10 * log10(item.energy / item.duration) : nil
            return Session(id: "\(device)|\(item.start.timeIntervalSince1970)|\(item.end.timeIntervalSince1970)",
                           device: device,
                           start: item.start,
                           end: item.end,
                           duration: item.duration,
                           decibels: decibels)
        }
        let duration = sessions.reduce(0) { $0 + $1.duration }
        let longest = sessions.map(\.duration).max() ?? 0
        let count = sessions.count
        let energy = merged.reduce(0) { $0 + $1.energy }
        let averageDecibels = duration > 0 ? 10 * log10(energy / duration) : nil
        let calendar = Calendar.current
        var hourTotals = Array(repeating: 0.0, count: 24)
        var dayTotals: [Date: TimeInterval] = [:]
        for session in sessions {
            let hour = calendar.component(.hour, from: session.start)
            hourTotals[hour] += session.duration
            let day = calendar.startOfDay(for: session.start)
            dayTotals[day, default: 0] += session.duration
        }
        let peakHour = hourTotals.enumerated().max { $0.element < $1.element }?.offset ?? 0
        let windowStart = peakHour
        let windowDuration = hourTotals[windowStart] + hourTotals[(windowStart + 1) % 24]
        let weekday = dayTotals.filter { !calendar.isDateInWeekend($0.key) }
        let weekend = dayTotals.filter { calendar.isDateInWeekend($0.key) }
        let weekdayAverage = weekday.isEmpty ? 0 : weekday.values.reduce(0, +) / Double(weekday.count)
        let weekendAverage = weekend.isEmpty ? 0 : weekend.values.reduce(0, +) / Double(weekend.count)
        let loudDuration = sorted.filter { $0.decibels >= 80 }.reduce(0) { $0 + $1.end.timeIntervalSince($1.start) }
        var loudBuckets = Array(repeating: 0.0, count: 4)
        for slice in sorted {
            let length = max(slice.end.timeIntervalSince(slice.start), 0)
            let bucket: Int
            if slice.decibels < 70 { bucket = 0 }
            else if slice.decibels < 80 { bucket = 1 }
            else if slice.decibels < 90 { bucket = 2 }
            else { bucket = 3 }
            loudBuckets[bucket] += length
        }
        return SessionStats(
            duration: duration,
            count: count,
            average: count > 0 ? duration / Double(count) : 0,
            longest: longest,
            averageDecibels: averageDecibels,
            peakDecibels: sorted.map(\.decibels).max(),
            loudDuration: loudDuration,
            lastUsed: sessions.map(\.end).max(),
            daysUsed: dayTotals.count,
            peakPeriod: String(format: "%02d:00 – %02d:00", windowStart, (windowStart + 2) % 24),
            peakShare: duration > 0 ? windowDuration / duration : 0,
            weekdayAverage: weekdayAverage,
            weekendAverage: weekendAverage,
            longestDay: dayTotals.values.max() ?? 0,
            currentStreak: streaks(dayTotals).current,
            longestStreak: streaks(dayTotals).longest,
            hourly: hourTotals,
            loudBuckets: loudBuckets,
            dailyMap: dayTotals,
            sessions: sessions
        )
    }

    /// 连续有记录的天数。今天还没听时，从昨天往回算。
    private static func streaks(_ days: [Date: TimeInterval]) -> (current: Int, longest: Int) {
        let calendar = Calendar.current
        let sorted = days.filter { $0.value > 0 }.keys.sorted()
        guard !sorted.isEmpty else { return (0, 0) }
        var longest = 1
        var run = 1
        for index in 1..<sorted.count {
            let gap = calendar.dateComponents([.day], from: sorted[index - 1], to: sorted[index]).day ?? 0
            run = gap == 1 ? run + 1 : 1
            longest = max(longest, run)
        }
        var current = 0
        var cursor = calendar.startOfDay(for: Date())
        if (days[cursor] ?? 0) <= 0 {
            cursor = calendar.date(byAdding: .day, value: -1, to: cursor) ?? cursor
        }
        while let value = days[cursor], value > 0 {
            current += 1
            guard current < 4000,
                  let previous = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = previous
        }
        return (current, longest)
    }

    private func loudEventCounts(range: Range) async -> [String: Int] {
        guard let events = HKObjectType.categoryType(forIdentifier: .headphoneAudioExposureEvent) else { return [:] }
        let predicate = HKQuery.predicateForSamples(withStart: range.startDate, end: Date(), options: .strictStartDate)
        let samples: [HKSample] = await withCheckedContinuation { continuation in
            let query = HKSampleQuery(sampleType: events, predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, result, _ in
                continuation.resume(returning: result ?? [])
            }
            healthStore.execute(query)
        }
        var counts: [String: Int] = [:]
        for sample in samples {
            let raw = (sample.device?.name ?? sample.device?.model)
                ?? (sample.metadata?[HKMetadataKeyDeviceName] as? String)
            let name = raw?.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = (name?.isEmpty == false) ? name! : "未标明设备"
            counts[key, default: 0] += 1
        }
        return counts
    }
}
#endif
