#if os(iOS)
import Foundation
import HealthKit

/// 从健康 App 的「耳机音量」记录里按设备型号聚合佩戴时长。
/// 健康数据只在本机读取，不上传。
@MainActor
final class AudioDeviceStatsStore: ObservableObject {
    struct Device: Identifiable {
        let id: String
        let name: String
        var duration: TimeInterval
        var share: Double
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
    @Published private(set) var isLoading = false
    @Published private(set) var isAuthorized = false
    @Published var errorMessage: String?

    private let healthStore = HKHealthStore()

    static var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    private var exposureType: HKQuantityType? {
        HKObjectType.quantityType(forIdentifier: .headphoneAudioExposure)
    }

    func requestAuthorization() async -> Bool {
        guard let exposureType else {
            errorMessage = "这台设备不支持耳机音量数据"
            return false
        }
        let granted: Bool = await withCheckedContinuation { continuation in
            healthStore.requestAuthorization(toShare: [], read: [exposureType]) { success, _ in
                continuation.resume(returning: success)
            }
        }
        isAuthorized = granted
        if !granted {
            errorMessage = "没有获得健康数据权限，请在系统设置里允许读取耳机音量"
        }
        return granted
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

        var buckets: [String: [(Date, Date)]] = [:]
        for case let sample as HKQuantitySample in samples {
            let name = (sample.metadata?[HKMetadataKeyDeviceName] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let name, !name.isEmpty else { continue }
            buckets[name, default: []].append((sample.startDate, sample.endDate))
        }

        // 健康数据里同一分钟可能有多条，先合并重叠区间再累加。
        var aggregated: [Device] = buckets.map { entry in
            Device(id: entry.key,
                   name: entry.key,
                   duration: Self.mergedDuration(entry.value),
                   share: 0)
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

    private static func mergedDuration(_ intervals: [(Date, Date)]) -> TimeInterval {
        let sorted = intervals.filter { $0.1 > $0.0 }.sorted { $0.0 < $1.0 }
        var total: TimeInterval = 0
        var currentStart: Date?
        var currentEnd: Date?
        for (start, end) in sorted {
            if let existingEnd = currentEnd, start <= existingEnd {
                currentEnd = max(existingEnd, end)
            } else {
                if let begin = currentStart, let finish = currentEnd {
                    total += finish.timeIntervalSince(begin)
                }
                currentStart = start
                currentEnd = end
            }
        }
        if let begin = currentStart, let finish = currentEnd {
            total += finish.timeIntervalSince(begin)
        }
        return total
    }
}
#endif
