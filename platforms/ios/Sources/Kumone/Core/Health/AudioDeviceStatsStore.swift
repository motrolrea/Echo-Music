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
    @Published private(set) var isRequesting = false
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
        isRequesting = true
        defer { isRequesting = false }
        let outcome: Result<Bool, Error> = await withCheckedContinuation { continuation in
            healthStore.requestAuthorization(toShare: [], read: [exposureType]) { success, error in
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

        if samples.isEmpty {
            devices = []
            totalDuration = 0
            if errorMessage == nil {
                errorMessage = "请求已结束，但没有读到耳机音量。如果刚才没有弹出系统授权框，就是安装包里的 HealthKit 权限被重签去掉了。"
            }
            return
        }

        var buckets: [String: [(Date, Date)]] = [:]
        for case let sample as HKQuantitySample in samples {
            let raw = (sample.device?.name ?? sample.device?.model)
                ?? (sample.metadata?[HKMetadataKeyDeviceName] as? String)
            let name = raw?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let name, !name.isEmpty else { continue }
            let host = ["iPhone", "iPad", "iPod", "Watch", "Apple TV", "Mac"]
            if host.contains(where: { name.localizedCaseInsensitiveContains($0) }) { continue }
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
