#if os(iOS)
import Combine
import CoreMotion
import Foundation
import HealthKit

/// 锻炼页打开时收起底栏和迷你播放器，只留封面上的唱片。
@MainActor
final class WorkoutChrome: ObservableObject {
    static let shared = WorkoutChrome()
    @Published var active = false
}

struct WorkoutRecord: Codable, Identifiable, Equatable {
    var id: UUID
    var activity: String
    var startedAt: Date
    var endedAt: Date
    var steps: Int?
    var distance: Double?
    var energy: Double?
}

/// 手动开始、手动结束的听歌锻炼。手机能测的才显示，测不到显示「—」。
@MainActor
final class WorkoutSessionStore: ObservableObject {
    struct PlayedSong: Identifiable, Equatable {
        let id: String
        let title: String
        let artist: String
    }

    enum Activity: String, CaseIterable, Identifiable {
        case walk
        case run
        case cycle

        var id: String { rawValue }

        var title: String {
            switch self {
            case .walk: return "户外步行"
            case .run: return "户外跑步"
            case .cycle: return "户外骑行"
            }
        }

        var shortTitle: String {
            switch self {
            case .walk: return "步行"
            case .run: return "跑步"
            case .cycle: return "骑行"
            }
        }

        static func matching(_ type: HKWorkoutActivityType) -> Activity? {
            switch type {
            case .walking: return .walk
            case .running: return .run
            case .cycling: return .cycle
            default: return nil
            }
        }

        var symbol: String {
            switch self {
            case .walk: return "figure.walk"
            case .run: return "figure.run"
            case .cycle: return "figure.outdoor.cycle"
            }
        }

        var workoutType: HKWorkoutActivityType {
            switch self {
            case .walk: return .walking
            case .run: return .running
            case .cycle: return .cycling
            }
        }
    }

    @Published private(set) var activity: Activity = .walk
    @Published private(set) var isRunning = false
    @Published private(set) var startedAt: Date?
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var steps: Int?
    @Published private(set) var distance: Double?
    @Published private(set) var pace: TimeInterval?
    @Published private(set) var floors: Int?
    @Published private(set) var heartRate: Double?
    @Published private(set) var activeEnergy: Double?
    @Published private(set) var songs: [PlayedSong] = []
    @Published private(set) var records: [WorkoutRecord] = []
    @Published private(set) var status = "点开始后才会记录"

    private static let recordsKey = "echo.workout.records"

    private let pedometer = CMPedometer()
    private let health = HKHealthStore()
    private var timer: Timer?
    private var heartQuery: HKQuery?
    private var savedSongIDs = Set<String>()
    private var cancellable: AnyCancellable?

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.recordsKey),
           let saved = try? JSONDecoder().decode([WorkoutRecord].self, from: data) {
            records = saved
        }
    }

    func select(_ activity: Activity) {
        guard !isRunning else { return }
        self.activity = activity
    }

    func start(player: PlayerService) {
        guard !isRunning else { return }
        isRunning = true
        startedAt = Date()
        elapsed = 0
        steps = CMPedometer.isStepCountingAvailable() ? 0 : nil
        distance = CMPedometer.isDistanceAvailable() ? 0 : nil
        pace = nil
        floors = CMPedometer.isFloorCountingAvailable() ? 0 : nil
        heartRate = nil
        activeEnergy = nil
        songs = []
        savedSongIDs = []
        status = "正在记录"
        remember(player.currentTrack)
        cancellable = player.$currentTrack
            .receive(on: DispatchQueue.main)
            .sink { [weak self] track in self?.remember(track) }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        startPedometer()
        Task { await startHealth() }
    }

    func stop() async {
        guard isRunning, let startedAt else { return }
        isRunning = false
        timer?.invalidate()
        timer = nil
        cancellable = nil
        pedometer.stopUpdates()
        if let heartQuery {
            health.stop(heartQuery)
            self.heartQuery = nil
        }
        let endedAt = Date()
        elapsed = endedAt.timeIntervalSince(startedAt)
        rememberRecord(from: startedAt, to: endedAt)
        await saveWorkout(from: startedAt, to: endedAt)
        status = "已结束"
    }

    private func rememberRecord(from start: Date, to end: Date) {
        records.insert(WorkoutRecord(id: UUID(),
                                      activity: activity.rawValue,
                                      startedAt: start,
                                      endedAt: end,
                                      steps: steps,
                                      distance: distance,
                                      energy: activeEnergy), at: 0)
        persistRecords()
    }

    /// 读健康 App 近 7 天的户外步行、跑步、骑行。和本地记录按开始时间去重。
    func importRecentHealthWorkouts() async {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        var readable: [HKObjectType] = [HKObjectType.workoutType()]
        for identifier in [HKQuantityTypeIdentifier.distanceWalkingRunning, .distanceCycling, .activeEnergyBurned] {
            if let type = HKObjectType.quantityType(forIdentifier: identifier) { readable.append(type) }
        }
        let granted = await withCheckedContinuation { continuation in
            health.requestAuthorization(toShare: [HKObjectType.workoutType()], read: Set(readable)) { success, _ in
                continuation.resume(returning: success)
            }
        }
        guard granted else { return }
        let start = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? .distantPast
        let predicate = HKQuery.predicateForSamples(withStart: start, end: Date(), options: .strictStartDate)
        let workouts: [HKWorkout] = await withCheckedContinuation { continuation in
            let query = HKSampleQuery(sampleType: HKObjectType.workoutType(),
                                       predicate: predicate,
                                       limit: 80,
                                       sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)]) { _, samples, _ in
                continuation.resume(returning: (samples as? [HKWorkout]) ?? [])
            }
            health.execute(query)
        }
        var changed = false
        for workout in workouts {
            guard let activity = Activity.matching(workout.workoutActivityType) else { continue }
            if records.contains(where: {
                $0.activity == activity.rawValue && abs($0.startedAt.timeIntervalSince(workout.startDate)) < 5
            }) { continue }
            let distanceIdentifier: HKQuantityTypeIdentifier = workout.workoutActivityType == .cycling ? .distanceCycling : .distanceWalkingRunning
            let distance = HKObjectType.quantityType(forIdentifier: distanceIdentifier)
                .flatMap { workout.statistics(for: $0)?.sumQuantity()?.doubleValue(for: .meter()) }
            let energy = HKObjectType.quantityType(forIdentifier: .activeEnergyBurned)
                .flatMap { workout.statistics(for: $0)?.sumQuantity()?.doubleValue(for: .kilocalorie()) }
            records.append(WorkoutRecord(id: UUID(),
                                          activity: activity.rawValue,
                                          startedAt: workout.startDate,
                                          endedAt: workout.endDate,
                                          steps: nil,
                                          distance: distance,
                                          energy: energy))
            changed = true
        }
        if changed {
            records.sort { $0.startedAt > $1.startedAt }
            persistRecords()
        }
    }

    private func persistRecords() {
        if records.count > 200 { records = Array(records.prefix(200)) }
        if let data = try? JSONEncoder().encode(records) {
            UserDefaults.standard.set(data, forKey: Self.recordsKey)
        }
    }

    private func tick() {
        guard let startedAt, isRunning else { return }
        elapsed = Date().timeIntervalSince(startedAt)
    }

    private func remember(_ track: Track?) {
        guard isRunning, let track else { return }
        let key = "\(track.source ?? "local")-\(track.id)-\(track.name)"
        guard savedSongIDs.insert(key).inserted else { return }
        songs.append(PlayedSong(id: key, title: track.name, artist: track.artistNames))
    }

    private func startPedometer() {
        guard CMPedometer.isStepCountingAvailable(), let startedAt else {
            status = "这台手机不能计步，时长和歌曲仍在记录"
            return
        }
        pedometer.startUpdates(from: startedAt) { [weak self] data, _ in
            guard let data else { return }
            Task { @MainActor in
                guard let self, self.isRunning else { return }
                self.steps = data.numberOfSteps.intValue
                if let meters = data.distance?.doubleValue { self.distance = meters }
                if let seconds = data.currentPace?.doubleValue, seconds > 0 { self.pace = seconds }
                if let floors = data.floorsAscended?.intValue { self.floors = floors }
            }
        }
    }

    private func startHealth() async {
        guard HKHealthStore.isHealthDataAvailable(),
              let heart = HKObjectType.quantityType(forIdentifier: .heartRate),
              let energy = HKObjectType.quantityType(forIdentifier: .activeEnergyBurned)
        else { return }
        let granted = await withCheckedContinuation { continuation in
            health.requestAuthorization(toShare: [HKObjectType.workoutType()], read: [heart, energy]) { success, _ in
                continuation.resume(returning: success)
            }
        }
        guard granted, isRunning, let startedAt else { return }
        let predicate = HKQuery.predicateForSamples(withStart: startedAt, end: nil, options: .strictStartDate)
        let query = HKAnchoredObjectQuery(type: heart, predicate: predicate, anchor: nil, limit: HKObjectQueryNoLimit) { [weak self] _, samples, _, _, _ in
            self?.applyHeart(samples)
        }
        query.updateHandler = { [weak self] _, samples, _, _, _ in
            self?.applyHeart(samples)
        }
        heartQuery = query
        health.execute(query)
        await refreshEnergy(type: energy, since: startedAt)
    }

    private nonisolated func applyHeart(_ samples: [HKSample]?) {
        guard let sample = samples?.compactMap({ $0 as? HKQuantitySample }).last else { return }
        let unit = HKUnit.count().unitDivided(by: .minute())
        let value = sample.quantity.doubleValue(for: unit)
        Task { @MainActor in self.heartRate = value }
    }

    private func refreshEnergy(type: HKQuantityType, since start: Date) async {
        let predicate = HKQuery.predicateForSamples(withStart: start, end: Date(), options: .strictStartDate)
        let value: Double? = await withCheckedContinuation { continuation in
            let query = HKStatisticsQuery(quantityType: type, quantitySamplePredicate: predicate, options: .cumulativeSum) { _, stats, _ in
                let kilocalories = stats?.sumQuantity()?.doubleValue(for: .kilocalorie())
                continuation.resume(returning: kilocalories)
            }
            health.execute(query)
        }
        if let value { activeEnergy = value }
    }

    private func saveWorkout(from start: Date, to end: Date) async {
        if let energyType = HKObjectType.quantityType(forIdentifier: .activeEnergyBurned) {
            await refreshEnergy(type: energyType, since: start)
        }
        let configuration = HKWorkoutConfiguration()
        configuration.activityType = activity.workoutType
        configuration.locationType = .outdoor
        let builder = HKWorkoutBuilder(healthStore: health, configuration: configuration, device: .local())
        let began: Bool = await withCheckedContinuation { continuation in
            builder.beginCollection(withStart: start) { success, _ in
                continuation.resume(returning: success)
            }
        }
        guard began else { return }
        var samples: [HKSample] = []
        let distanceIdentifier: HKQuantityTypeIdentifier = activity.workoutType == .cycling ? .distanceCycling : .distanceWalkingRunning
        if let meters = distance, meters > 0,
           let type = HKObjectType.quantityType(forIdentifier: distanceIdentifier) {
            samples.append(HKQuantitySample(type: type, quantity: HKQuantity(unit: .meter(), doubleValue: meters), start: start, end: end))
        }
        if let kilocalories = activeEnergy, kilocalories > 0,
           let type = HKObjectType.quantityType(forIdentifier: .activeEnergyBurned) {
            samples.append(HKQuantitySample(type: type, quantity: HKQuantity(unit: .kilocalorie(), doubleValue: kilocalories), start: start, end: end))
        }
        if !samples.isEmpty {
            await withCheckedContinuation { continuation in
                builder.add(samples) { _, _ in continuation.resume() }
            }
        }
        await withCheckedContinuation { continuation in
            builder.endCollection(withEnd: end) { _, _ in
                builder.finishWorkout { _, _ in
                    continuation.resume()
                }
            }
        }
    }
}
#endif
