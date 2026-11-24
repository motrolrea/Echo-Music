#if os(iOS)
import Combine
import CoreLocation
import CoreMotion
import Foundation
import HealthKit

/// 锻炼页打开时收起底栏和迷你播放器，只留封面上的唱片。
@MainActor
final class WorkoutChrome: ObservableObject {
    static let shared = WorkoutChrome()
    @Published var active = false
}

struct WorkoutSong: Codable, Identifiable, Equatable {
    var id: String
    var title: String
    var artist: String
    var coverURL: String?
    var playedAt: Date
}

/// 锻炼过程中的一个采样点。配速是秒/米，越小越快。
struct WorkoutSample: Codable, Equatable {
    var at: Date
    var distance: Double?
    var pace: TimeInterval?
    var heartRate: Double?
    var steps: Int?
    var energy: Double?
    var floors: Int?
    var floorsDescended: Int?
}

struct WorkoutPacePoint: Equatable {
    var at: Date
    var pace: TimeInterval
}

/// 用相邻采样点的距离差算出一段配速，比瞬时值稳。
func workoutPacePoints(_ samples: [WorkoutSample]) -> [WorkoutPacePoint] {
    let ordered = samples.sorted { $0.at < $1.at }
    var points: [WorkoutPacePoint] = []
    for pair in zip(ordered, ordered.dropFirst()) {
        guard let start = pair.0.distance, let end = pair.1.distance else { continue }
        let meters = end - start
        let seconds = pair.1.at.timeIntervalSince(pair.0.at)
        guard meters >= 12, seconds >= 8 else { continue }
        let pace = seconds / meters
        guard pace > 0.04, pace < 3 else { continue }
        points.append(WorkoutPacePoint(at: pair.1.at, pace: pace))
    }
    return points
}

struct WorkoutSplit: Identifiable, Equatable {
    var kilometer: Int
    var pace: TimeInterval
    var at: Date
    var id: Int { kilometer }
}

func workoutSplits(_ samples: [WorkoutSample]) -> [WorkoutSplit] {
    let ordered = samples.sorted { $0.at < $1.at }
    guard let first = ordered.first, let origin = first.distance else { return [] }
    var splits: [WorkoutSplit] = []
    var mark = 1000.0
    var anchor = first
    for sample in ordered.dropFirst() {
        guard let distance = sample.distance else { continue }
        while distance - origin >= mark {
            let meters = distance - (anchor.distance ?? origin)
            let seconds = sample.at.timeIntervalSince(anchor.at)
            if meters > 50, seconds > 20 {
                let pace = seconds / meters
                if pace > 0.04, pace < 3 {
                    splits.append(WorkoutSplit(kilometer: Int(mark / 1000), pace: pace, at: sample.at))
                }
            }
            anchor = sample
            mark += 1000
            if splits.count >= 80 { return splits }
        }
    }
    return splits
}

struct WorkoutRecord: Codable, Identifiable, Equatable {
    var id: UUID
    var activity: String
    var startedAt: Date
    var endedAt: Date
    var steps: Int?
    var distance: Double?
    var energy: Double?
    var floors: Int?
    var floorsDescended: Int?
    var averagePace: TimeInterval?
    var fastestPace: TimeInterval?
    var fastestPaceAt: Date?
    var slowestPace: TimeInterval?
    var peakHeartRate: Double?
    var peakHeartRateAt: Date?
    var averageHeartRate: Double?
    var songs: [WorkoutSong]
    var samples: [WorkoutSample]
    /// 纬度、经度成对保存。旧记录没有这条，解码成空路线。
    var route: [Double]

    init(id: UUID, activity: String, startedAt: Date, endedAt: Date,
         steps: Int? = nil, distance: Double? = nil, energy: Double? = nil,
         floors: Int? = nil, floorsDescended: Int? = nil, averagePace: TimeInterval? = nil,
         fastestPace: TimeInterval? = nil, fastestPaceAt: Date? = nil,
         slowestPace: TimeInterval? = nil, peakHeartRate: Double? = nil,
         peakHeartRateAt: Date? = nil, averageHeartRate: Double? = nil,
         songs: [WorkoutSong] = [], samples: [WorkoutSample] = [],
         route: [Double] = []) {
        self.id = id
        self.activity = activity
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.steps = steps
        self.distance = distance
        self.energy = energy
        self.floors = floors
        self.floorsDescended = floorsDescended
        self.averagePace = averagePace
        self.fastestPace = fastestPace
        self.fastestPaceAt = fastestPaceAt
        self.slowestPace = slowestPace
        self.peakHeartRate = peakHeartRate
        self.peakHeartRateAt = peakHeartRateAt
        self.averageHeartRate = averageHeartRate
        self.songs = songs
        self.samples = samples
        self.route = route
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        activity = try container.decode(String.self, forKey: .activity)
        startedAt = try container.decode(Date.self, forKey: .startedAt)
        endedAt = try container.decode(Date.self, forKey: .endedAt)
        steps = try container.decodeIfPresent(Int.self, forKey: .steps)
        distance = try container.decodeIfPresent(Double.self, forKey: .distance)
        energy = try container.decodeIfPresent(Double.self, forKey: .energy)
        floors = try container.decodeIfPresent(Int.self, forKey: .floors)
        floorsDescended = try container.decodeIfPresent(Int.self, forKey: .floorsDescended)
        averagePace = try container.decodeIfPresent(TimeInterval.self, forKey: .averagePace)
        fastestPace = try container.decodeIfPresent(TimeInterval.self, forKey: .fastestPace)
        fastestPaceAt = try container.decodeIfPresent(Date.self, forKey: .fastestPaceAt)
        slowestPace = try container.decodeIfPresent(TimeInterval.self, forKey: .slowestPace)
        peakHeartRate = try container.decodeIfPresent(Double.self, forKey: .peakHeartRate)
        peakHeartRateAt = try container.decodeIfPresent(Date.self, forKey: .peakHeartRateAt)
        averageHeartRate = try container.decodeIfPresent(Double.self, forKey: .averageHeartRate)
        songs = try container.decodeIfPresent([WorkoutSong].self, forKey: .songs) ?? []
        samples = try container.decodeIfPresent([WorkoutSample].self, forKey: .samples) ?? []
        route = try container.decodeIfPresent([Double].self, forKey: .route) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(activity, forKey: .activity)
        try container.encode(startedAt, forKey: .startedAt)
        try container.encode(endedAt, forKey: .endedAt)
        try container.encodeIfPresent(steps, forKey: .steps)
        try container.encodeIfPresent(distance, forKey: .distance)
        try container.encodeIfPresent(energy, forKey: .energy)
        try container.encodeIfPresent(floors, forKey: .floors)
        try container.encodeIfPresent(floorsDescended, forKey: .floorsDescended)
        try container.encodeIfPresent(averagePace, forKey: .averagePace)
        try container.encodeIfPresent(fastestPace, forKey: .fastestPace)
        try container.encodeIfPresent(fastestPaceAt, forKey: .fastestPaceAt)
        try container.encodeIfPresent(slowestPace, forKey: .slowestPace)
        try container.encodeIfPresent(peakHeartRate, forKey: .peakHeartRate)
        try container.encodeIfPresent(peakHeartRateAt, forKey: .peakHeartRateAt)
        try container.encodeIfPresent(averageHeartRate, forKey: .averageHeartRate)
        try container.encode(songs, forKey: .songs)
        try container.encode(samples, forKey: .samples)
        try container.encode(route, forKey: .route)
    }

    var coordinates: [CLLocationCoordinate2D] {
        stride(from: 0, to: route.count - 1, by: 2).map {
            CLLocationCoordinate2D(latitude: route[$0], longitude: route[$0 + 1])
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id, activity, startedAt, endedAt, steps, distance, energy, floors, floorsDescended
        case averagePace, fastestPace, fastestPaceAt, slowestPace
        case peakHeartRate, peakHeartRateAt, averageHeartRate, songs, samples, route
    }
}

/// 手动开始、手动结束的听歌锻炼。手机能测的才显示，测不到显示「—」。
@MainActor
final class WorkoutSessionStore: ObservableObject {
    /// 全局一份。离开锻炼页后计时、计步和健康查询继续跑。
    static let shared = WorkoutSessionStore()
    let location = WorkoutLocationTracker()

    struct PlayedSong: Identifiable, Equatable {
        let id: String
        let title: String
        let artist: String
        let coverURL: String?
        let playedAt: Date
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
    @Published private(set) var floorsDescended: Int?
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
    private var samples: [WorkoutSample] = []
    private var lastSampleAt: Date?
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
        floorsDescended = CMPedometer.isFloorCountingAvailable() ? 0 : nil
        heartRate = nil
        activeEnergy = nil
        songs = []
        samples = []
        lastSampleAt = nil
        status = "正在记录"
        location.reset()
        location.start()
        captureSample(force: true)
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
        captureSample(force: true)
        isRunning = false
        timer?.invalidate()
        timer = nil
        cancellable = nil
        pedometer.stopUpdates()
        location.stop()
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
        let length = end.timeIntervalSince(start)
        let average = (distance ?? 0) > 0 ? length / distance! : nil
        let points = workoutPacePoints(samples)
        let instant = samples.filter { sample in
            guard let pace = sample.pace else { return false }
            return pace > 0.04 && pace < 3
        }
        let fastest = points.min { $0.pace < $1.pace }
            ?? instant.min { ($0.pace ?? 0) < ($1.pace ?? 0) }.map { WorkoutPacePoint(at: $0.at, pace: $0.pace ?? 0) }
        let slowest = points.max { $0.pace < $1.pace }
            ?? instant.max { ($0.pace ?? 0) < ($1.pace ?? 0) }.map { WorkoutPacePoint(at: $0.at, pace: $0.pace ?? 0) }
        let hearts = samples.compactMap(\.heartRate)
        let peakHeart = samples.filter { $0.heartRate != nil }.max { ($0.heartRate ?? 0) < ($1.heartRate ?? 0) }
        records.insert(WorkoutRecord(id: UUID(),
                                      activity: activity.rawValue,
                                      startedAt: start,
                                      endedAt: end,
                                      steps: steps,
                                      distance: distance,
                                      energy: activeEnergy,
                                      floors: floors,
                                      floorsDescended: floorsDescended,
                                      averagePace: average,
                                      fastestPace: fastest?.pace,
                                      fastestPaceAt: fastest?.at,
                                      slowestPace: slowest?.pace,
                                      peakHeartRate: peakHeart?.heartRate,
                                      peakHeartRateAt: peakHeart?.at,
                                      averageHeartRate: hearts.isEmpty ? nil : hearts.reduce(0, +) / Double(hearts.count),
                                      songs: songs.map {
                                          WorkoutSong(id: $0.id, title: $0.title, artist: $0.artist,
                                                      coverURL: $0.coverURL, playedAt: $0.playedAt)
                                      },
                                      samples: samples,
                                      route: location.route.flatMap { [$0.latitude, $0.longitude] }), at: 0)
        persistRecords()
    }

    /// 大约每 15 秒留一个点，用来事后找最快的一段。
    private func captureSample(force: Bool = false) {
        guard isRunning || force else { return }
        let now = Date()
        if !force, let lastSampleAt, now.timeIntervalSince(lastSampleAt) < 15 { return }
        lastSampleAt = now
        samples.append(WorkoutSample(at: now,
                                      distance: distance,
                                      pace: pace,
                                      heartRate: heartRate,
                                      steps: steps,
                                      energy: activeEnergy,
                                      floors: floors,
                                      floorsDescended: floorsDescended))
        if samples.count > 800 { samples.removeFirst(samples.count - 800) }
    }

    /// 读健康 App 近 90 天的户外步行、跑步、骑行。和本地记录按开始时间去重。
    func importRecentHealthWorkouts() async {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        var readable: [HKObjectType] = [HKObjectType.workoutType()]
        for identifier in [HKQuantityTypeIdentifier.distanceWalkingRunning, .distanceCycling,
                           .activeEnergyBurned, .heartRate, .flightsClimbed] {
            if let type = HKObjectType.quantityType(forIdentifier: identifier) { readable.append(type) }
        }
        let granted = await withCheckedContinuation { continuation in
            health.requestAuthorization(toShare: [HKObjectType.workoutType()], read: Set(readable)) { success, _ in
                continuation.resume(returning: success)
            }
        }
        guard granted else { return }
        let start = Calendar.current.date(byAdding: .day, value: -90, to: Date()) ?? .distantPast
        let predicate = HKQuery.predicateForSamples(withStart: start, end: Date(), options: .strictStartDate)
        let workouts: [HKWorkout] = await withCheckedContinuation { continuation in
            let query = HKSampleQuery(sampleType: HKObjectType.workoutType(),
                                       predicate: predicate,
                                       limit: 150,
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
            let heartType = HKObjectType.quantityType(forIdentifier: .heartRate)
            let heartUnit = HKUnit.count().unitDivided(by: .minute())
            let averageHeart = heartType
                .flatMap { workout.statistics(for: $0)?.averageQuantity()?.doubleValue(for: heartUnit) }
            let peakHeart = heartType
                .flatMap { workout.statistics(for: $0)?.maximumQuantity()?.doubleValue(for: heartUnit) }
            let floors = HKObjectType.quantityType(forIdentifier: .flightsClimbed)
                .flatMap { workout.statistics(for: $0)?.sumQuantity()?.doubleValue(for: .count()) }
            let length = workout.endDate.timeIntervalSince(workout.startDate)
            let pace = (distance ?? 0) > 0 ? length / distance! : nil
            records.append(WorkoutRecord(id: UUID(),
                                          activity: activity.rawValue,
                                          startedAt: workout.startDate,
                                          endedAt: workout.endDate,
                                          distance: distance,
                                          energy: energy,
                                          floors: floors.map { Int($0.rounded()) },
                                          averagePace: pace,
                                          peakHeartRate: peakHeart,
                                          averageHeartRate: averageHeart))
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
        captureSample()
    }

    private func remember(_ track: Track?) {
        guard isRunning, let track else { return }
        let key = "\(track.source ?? "local")-\(track.id)-\(track.name)"
        if songs.last?.id.hasPrefix(key) == true { return }
        songs.append(PlayedSong(id: "\(key)-\(Int(Date().timeIntervalSince1970))",
                                 title: track.name,
                                 artist: track.artistNames,
                                 coverURL: track.album.picUrl,
                                 playedAt: Date()))
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
                if let floors = data.floorsDescended?.intValue { self.floorsDescended = floors }
            }
        }
    }

    private func startHealth() async {
        guard HKHealthStore.isHealthDataAvailable(),
              let heart = HKObjectType.quantityType(forIdentifier: .heartRate),
              let energy = HKObjectType.quantityType(forIdentifier: .activeEnergyBurned)
        else { return }
        let granted = await withCheckedContinuation { continuation in
            var read: Set<HKObjectType> = [heart, energy]
            if let steps = HKObjectType.quantityType(forIdentifier: .stepCount) { read.insert(steps) }
            if let distance = HKObjectType.quantityType(forIdentifier: .distanceWalkingRunning) { read.insert(distance) }
            health.requestAuthorization(toShare: [HKObjectType.workoutType()], read: read) { success, _ in
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
