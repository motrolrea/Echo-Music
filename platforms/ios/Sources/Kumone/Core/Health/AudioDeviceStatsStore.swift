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
    struct Device: Identifiable {
        let id: String
        let name: String
        var duration: TimeInterval
        var share: Double
        var sessionCount: Int
        var averageSession: TimeInterval
        var longestSession: TimeInterval
        var averageDecibels: Double?
        var peakDecibels: Double?
        var loudDuration: TimeInterval
        var lastUsed: Date?
        var daysUsed: Int
        var peakPeriod: String
        var peakShare: Double
        var weekdayAverage: TimeInterval
        var weekendAverage: TimeInterval
        var loudEvents: Int
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
            case .all: return "全部"
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

        let predicate = HKQuery.predicateForSamples(withStart: range.startDate,
                                                    end: Date(),
                                                    options: .strictStartDate)
        let samples: [HKSample] = await withCheckedContinuation { continuation in
            let query = HKSampleQuery(sampleType: exposureType,
                                      predicate: predicate,
                                      limit: HKObjectQueryNoLimit,
                                      sortDescriptors: nil) { _, result, _ in
                continuation.resume(returning: result ?? [])
            }
            healthStore.execute(query)
        }

        let eventCounts = await loudEventCounts(range: range)
        loudEvents = eventCounts.values.reduce(0, +)

        if samples.isEmpty, loudEvents == 0 {
            devices = []
            totalDuration = 0
            if errorMessage == nil {
                errorMessage = "请求已结束，但没有读到耳机音量。如果刚才没有弹出系统授权框，就是安装包里的 HealthKit 权限被重签去掉了。"
            }
            return
        }

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

        // 重叠只算一次。间隔超过 60 秒就另算一次佩戴。
        var aggregated: [Device] = buckets.map { entry in
            let stats = Self.sessionStats(entry.value)
            return Device(id: entry.key,
                          name: entry.key,
                          duration: stats.duration,
                          share: 0,
                          sessionCount: stats.count,
                          averageSession: stats.average,
                          longestSession: stats.longest,
                          averageDecibels: stats.averageDecibels,
                          peakDecibels: stats.peakDecibels,
                          loudDuration: stats.loudDuration,
                          lastUsed: stats.lastUsed,
                          daysUsed: stats.daysUsed,
                          peakPeriod: stats.peakPeriod,
                          peakShare: stats.peakShare,
                          weekdayAverage: stats.weekdayAverage,
                          weekendAverage: stats.weekendAverage,
                          loudEvents: eventCounts[entry.key, default: 0])
        }
        aggregated.sort { $0.duration > $1.duration }
        let total = aggregated.reduce(0) { $0 + $1.duration }
        devices = aggregated.map { device in
            var copy = device
            copy.share = total > 0 ? device.duration / total : 0
            return copy
        }
        totalDuration = total
        errorMessage = nil
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
    }

    /// 先合并重叠，再按 60 秒空隙切开。音量按能量加权，不是把分贝直接平均。
    private static func sessionStats(_ slices: [ExposureSlice]) -> SessionStats {
        let sorted = slices.sorted { $0.start < $1.start }
        var sessions: [(start: Date, end: Date, energy: Double, duration: TimeInterval)] = []
        for slice in sorted {
            let length = slice.end.timeIntervalSince(slice.start)
            let energy = pow(10, slice.decibels / 10) * length
            if var current = sessions.last, slice.start.timeIntervalSince(current.end) <= 60 {
                let overlap = max(0, current.end.timeIntervalSince(slice.start))
                current.end = max(current.end, slice.end)
                current.energy += energy * (length > 0 ? max(length - overlap, 0) / length : 0)
                current.duration += max(length - overlap, 0)
                sessions[sessions.count - 1] = current
            } else {
                sessions.append((slice.start, slice.end, energy, length))
            }
        }
        let duration = sessions.reduce(0) { $0 + $1.duration }
        let longest = sessions.map(\.duration).max() ?? 0
        let count = sessions.count
        let energy = sessions.reduce(0) { $0 + $1.energy }
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
            weekendAverage: weekendAverage
        )
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
