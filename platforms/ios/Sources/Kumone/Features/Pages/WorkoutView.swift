#if os(iOS)
import SwiftUI

/// 听歌锻炼。底栏收起，右上角只留一张旋转封面。
struct WorkoutView: View {
    @EnvironmentObject private var player: PlayerService
    @Environment(\.colorScheme) private var colorScheme
    @StateObject private var session = WorkoutSessionStore()
    @State private var focus: WorkoutSessionStore.Activity = .walk
    @State private var span: WorkoutSpan = .week
    @State private var customStart = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
    @State private var customEnd = Date()
    @State private var showCustomRange = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                modeSwitcher
                focusedHeader
                liveSession
                WorkoutPatternCard(records: rangedRecords) {
                    spanMenu
                }
                journal
            }
            .padding(.horizontal, 22)
            .padding(.top, 8)
            .padding(.bottom, 36)
            .animation(.spring(response: 0.42, dampingFraction: 0.86), value: focus)
        }
        .scrollIndicators(.hidden)
        .background(Color(.systemBackground).ignoresSafeArea())
        .sheet(isPresented: $showCustomRange) {
            customRangeSheet
        }
        .navigationTitle(focus.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                spinningDisc
            }
        }
        .onAppear {
            session.select(focus)
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { WorkoutChrome.shared.active = true }
            Task { await session.importRecentHealthWorkouts() }
        }
        .onDisappear {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { WorkoutChrome.shared.active = false }
        }
    }

    private var modeSwitcher: some View {
        HStack(spacing: 8) {
            ForEach(WorkoutSessionStore.Activity.allCases) { item in
                Button {
                    guard !session.isRunning else { return }
                    focus = item
                    session.select(item)
                } label: {
                    Label(item.shortTitle, systemImage: item.symbol)
                        .font(.subheadline.weight(focus == item ? .semibold : .regular))
                        .foregroundStyle(focus == item ? Color(.systemBackground) : .primary)
                        .frame(maxWidth: .infinity, minHeight: 36)
                        .background(focus == item ? Color.primary : Color.primary.opacity(0.08), in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(session.isRunning && focus != item)
            }
        }
    }

    private var focusedHeader: some View {
        HStack(spacing: 10) {
            Image(systemName: focus.symbol)
                .font(.system(size: 28, weight: .regular))
            Text(focus.title)
                .font(.title2.weight(.semibold))
        }
        .foregroundStyle(.primary)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    private var liveSession: some View {
        VStack(alignment: .center, spacing: 22) {
            VStack(spacing: 4) {
                Text(clock(session.elapsed))
                    .font(.system(size: 44, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text(session.status)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .multilineTextAlignment(.center)

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 18) {
                metric("步数", session.steps.map(String.init))
                metric("距离", meters(session.distance))
                metric("配速", pace(session.pace))
                metric("楼层 上/下", floorText)
                metric("心率", session.heartRate.map { "\(Int($0.rounded()))" })
                metric("能量", session.activeEnergy.map { "\(Int($0.rounded())) 千卡" })
            }

            Button {
                if session.isRunning {
                    Task { await session.stop() }
                } else {
                    session.start(player: player)
                }
            } label: {
                Text(session.isRunning ? "结束" : "开始")
                    .font(.headline)
                    .foregroundStyle(session.isRunning ? Color(.systemBackground) : .primary)
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .background(session.isRunning ? Color.primary : Color.primary.opacity(0.08), in: Capsule())
            }
            .buttonStyle(.plain)

            songsCard
        }
    }

    private var songsCard: some View {
        WorkoutCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 6) {
                    Image(systemName: "music.note")
                        .font(.system(size: 15, weight: .semibold))
                    Text("这次听过")
                        .font(.system(size: 18, weight: .semibold))
                }
                if session.songs.isEmpty {
                    Text(session.isRunning ? "切歌后记在这里" : "开始后记录播放过的歌")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(session.songs) { song in
                        HStack(spacing: 12) {
                            WorkoutCover(url: song.coverURL, size: 44)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(song.title).lineLimit(1)
                                Text("\(WorkoutText.time.string(from: song.playedAt)) · \(song.artist)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                }
            }
        }
    }

    private var floorText: String? {
        guard session.floors != nil || session.floorsDescended != nil else { return nil }
        let up = session.floors.map(String.init) ?? "—"
        let down = session.floorsDescended.map(String.init) ?? "—"
        return "\(up)/\(down)"
    }

    private func metric(_ title: String, _ value: String?) -> some View {
        VStack(spacing: 4) {
            Text(value ?? "—")
                .font(.system(size: 28, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .multilineTextAlignment(.center)
    }

    private var spinningDisc: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !player.isPlaying)) { timeline in
            let turn = timeline.date.timeIntervalSinceReferenceDate
                .truncatingRemainder(dividingBy: 8) / 8
            cover
                .rotationEffect(.degrees(player.isPlaying ? turn * 360 : 0))
        }
        .frame(width: 36, height: 36)
        .onTapGesture { player.showNowPlaying = true }
        .accessibilityLabel("正在播放")
    }

    private var cover: some View {
        CachedAsyncImage(url: player.currentTrack?.album.picUrl?.resizedImageURL(128)) {
            Image(systemName: "music.note")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.primary.opacity(colorScheme == .dark ? 0.12 : 0.06))
        }
        .scaledToFill()
        .frame(width: 36, height: 36)
        .clipShape(Circle())
        .overlay { Circle().strokeBorder(Color.primary.opacity(0.16), lineWidth: 0.6) }
    }

    private func clock(_ seconds: TimeInterval) -> String {
        let total = max(Int(seconds), 0)
        return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }

    private func meters(_ value: Double?) -> String? {
        guard let value else { return nil }
        if value >= 1000 { return String(format: "%.2f 公里", value / 1000) }
        return "\(Int(value.rounded())) 米"
    }

    private func pace(_ secondsPerMeter: TimeInterval?) -> String? {
        guard let secondsPerMeter, secondsPerMeter > 0 else { return nil }
        let perKilometer = Int((secondsPerMeter * 1000).rounded())
        return String(format: "%d'%02d\"", perKilometer / 60, perKilometer % 60)
    }

    private var spanTitle: String {
        switch span {
        case .week: return "近一周"
        case .month: return "近一个月"
        case .custom:
            return "\(WorkoutText.shortDay.string(from: min(customStart, customEnd))) – \(WorkoutText.shortDay.string(from: max(customStart, customEnd)))"
        }
    }

    private var spanMenu: some View {
        Menu {
            Button { span = .week } label: {
                if span == .week { Label("近一周", systemImage: "checkmark") } else { Text("近一周") }
            }
            Button { span = .month } label: {
                if span == .month { Label("近一个月", systemImage: "checkmark") } else { Text("近一个月") }
            }
            Button {
                span = .custom
                showCustomRange = true
            } label: {
                if span == .custom { Label("自选区间", systemImage: "checkmark") } else { Text("自选区间") }
            }
        } label: {
            HStack(spacing: 4) {
                Text(spanTitle)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
        }
    }

    private var rangedRecords: [WorkoutRecord] {
        let calendar = Calendar.current
        let latest = span == .custom ? max(customStart, customEnd) : Date()
        let earliest: Date
        switch span {
        case .week:
            earliest = calendar.date(byAdding: .day, value: -7, to: latest) ?? .distantPast
        case .month:
            earliest = calendar.date(byAdding: .month, value: -1, to: latest) ?? .distantPast
        case .custom:
            earliest = calendar.startOfDay(for: min(customStart, customEnd))
        }
        let end = span == .custom
            ? (calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: latest)) ?? latest)
            : latest.addingTimeInterval(1)
        return session.records.filter {
            $0.activity == focus.rawValue && $0.startedAt >= earliest && $0.startedAt < end && $0.endedAt > $0.startedAt
        }
    }

    private var journal: some View {
        WorkoutCard {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .firstTextBaseline) {
                    Text("记录")
                        .font(.title3.weight(.semibold))
                    Spacer()
                    Text("\(rangedRecords.count) 次")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if rangedRecords.isEmpty {
                    Text("这个区间还没有记录")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 8)
                } else {
                    ForEach(WorkoutDay.groups(rangedRecords)) { day in
                        VStack(alignment: .leading, spacing: 16) {
                            Text(WorkoutText.day.string(from: day.date))
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            ForEach(day.records) { record in
                                NavigationLink {
                                    WorkoutRecordDetail(record: record)
                                } label: {
                                    WorkoutJournalRow(record: record)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
        }
    }

    private var customRangeSheet: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("选择区间")
                .font(.title3.weight(.semibold))
            DatePicker("从", selection: $customStart, displayedComponents: .date)
            DatePicker("到", selection: $customEnd, displayedComponents: .date)
            Button("完成") { showCustomRange = false }
                .font(.headline)
                .frame(maxWidth: .infinity, minHeight: 48)
                .background(Color.primary, in: Capsule())
                .foregroundStyle(Color(.systemBackground))
        }
        .padding(22)
        .presentationDetents([.height(340)])
        .presentationDragIndicator(.visible)
    }
}

/// 所选区间的锻炼分布。区间由上面的菜单决定。
private struct WorkoutPatternCard<Header: View>: View {
    let records: [WorkoutRecord]
    @ViewBuilder var header: () -> Header

    var body: some View {
        let stats = PatternStats(records: records)
        VStack(alignment: .leading, spacing: 18) {
            header()
            Text(stats.peakPeriod)
                .font(.system(size: 28, weight: .semibold, design: .rounded))
            Text(stats.shareText)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            WorkoutClock(hours: stats.hours, peakHour: stats.peakHour)
                .frame(height: 160)
                .frame(maxWidth: .infinity)

            WorkoutHeatmap(cells: stats.cells)
                .frame(height: 132)

            HStack(alignment: .top, spacing: 12) {
                quietStat("次数", "\(stats.count)")
                quietStat("周中日均", stats.weekday > 0 ? workoutDuration(stats.weekday) : "—")
                quietStat("周末日均", stats.weekend > 0 ? workoutDuration(stats.weekend) : "—")
            }
        }
        .padding(18)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private func quietStat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value)
                .font(.title3.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct WorkoutCard<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

private struct PatternStats {
    let hours: [Double]
    let cells: [[Double]]
    let peakHour: Int
    let peakPeriod: String
    let shareText: String
    let weekday: TimeInterval
    let weekend: TimeInterval
    let count: Int

    init(records: [WorkoutRecord]) {
        let calendar = Calendar.current
        var hours = Array(repeating: 0.0, count: 24)
        var cells = Array(repeating: Array(repeating: 0.0, count: 24), count: 7)
        var weekdayTotal = 0.0
        var weekendTotal = 0.0
        var weekdayDays = Set<Date>()
        var weekendDays = Set<Date>()
        for record in records {
            let length = record.endedAt.timeIntervalSince(record.startedAt)
            let hour = calendar.component(.hour, from: record.startedAt)
            let weekday = calendar.component(.weekday, from: record.startedAt)
            let row = (weekday + 5) % 7
            hours[hour] += length
            cells[row][hour] += length
            let day = calendar.startOfDay(for: record.startedAt)
            if calendar.isDateInWeekend(record.startedAt) {
                weekendTotal += length
                weekendDays.insert(day)
            } else {
                weekdayTotal += length
                weekdayDays.insert(day)
            }
        }
        self.hours = hours
        self.cells = cells
        let peak = hours.enumerated().max { $0.element < $1.element }?.offset ?? 0
        peakHour = peak
        let total = hours.reduce(0, +)
        let window = hours[peak] + hours[(peak + 1) % 24]
        peakPeriod = total > 0
            ? String(format: "%02d:00 – %02d:00", peak, (peak + 2) % 24)
            : "还没有记录"
        let share = total > 0 ? Int((window / total * 100).rounded()) : 0
        shareText = total > 0 ? "这个时段占了所选时间的 \(share)%" : "这个区间还没有锻炼"
        weekday = weekdayDays.isEmpty ? 0 : weekdayTotal / Double(weekdayDays.count)
        weekend = weekendDays.isEmpty ? 0 : weekendTotal / Double(weekendDays.count)
        count = records.count
    }
}

private struct WorkoutClock: View {
    let hours: [Double]
    let peakHour: Int

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let peak = hours.max() ?? 0
            ZStack {
                Canvas { context, canvasSize in
                    let center = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
                    let radius = min(canvasSize.width, canvasSize.height) * 0.26
                    let ring = Path(ellipseIn: CGRect(x: center.x - radius,
                                                      y: center.y - radius,
                                                      width: radius * 2,
                                                      height: radius * 2))
                    context.stroke(ring,
                                   with: .color(Color.primary.opacity(0.18)),
                                   style: StrokeStyle(lineWidth: 1.6, lineCap: .round, dash: [1, 6]))

                    for hour in 0..<24 {
                        let angle = CGFloat(hour) / 24 * .pi * 2 - .pi / 2
                        let strength = peak > 0 ? min(max(hours[hour] / peak, 0), 1) : 0
                        let isPeak = hour == peakHour && peak > 0
                        let inner = radius + 3
                        let length = radius * (0.08 + CGFloat(strength) * 0.36)
                            + (isPeak ? radius * 0.07 : 0)
                        let width: CGFloat = isPeak ? 4.6 : 2.2 + CGFloat(strength) * 1.2
                        var bar = Path()
                        bar.move(to: CGPoint(x: center.x + cos(angle) * inner,
                                             y: center.y + sin(angle) * inner))
                        bar.addLine(to: CGPoint(x: center.x + cos(angle) * (inner + length),
                                                y: center.y + sin(angle) * (inner + length)))
                        if isPeak {
                            context.stroke(bar,
                                           with: .color(Color.primary.opacity(0.10)),
                                           style: StrokeStyle(lineWidth: 12, lineCap: .round))
                        }
                        context.stroke(bar,
                                       with: .color(Color.primary.opacity(0.18 + strength * 0.82)),
                                       style: StrokeStyle(lineWidth: width, lineCap: .round))
                        if isPeak {
                            let tip = CGPoint(x: center.x + cos(angle) * (inner + length),
                                              y: center.y + sin(angle) * (inner + length))
                            context.fill(Path(ellipseIn: CGRect(x: tip.x - 2.2, y: tip.y - 2.2,
                                                                width: 4.4, height: 4.4)),
                                         with: .color(Theme.accent))
                        }
                    }
                }

                VStack(spacing: 2) {
                    Text(peak > 0 ? "\(peakHour) 点" : "—")
                        .font(.system(size: 24, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    Text("最高峰")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Text("0")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .position(x: size.width / 2, y: size.height * 0.045)
                Text("6")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .position(x: size.width * 0.955, y: size.height / 2)
                Text("12")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .position(x: size.width / 2, y: size.height * 0.955)
                Text("18")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .position(x: size.width * 0.045, y: size.height / 2)
            }
            .frame(width: size.width, height: size.height)
        }
    }
}

private struct WorkoutHeatmap: View {
    let cells: [[Double]]

    var body: some View {
        let peak = cells.flatMap { $0 }.max() ?? 0
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 2) {
                Text(" ")
                    .frame(width: 16)
                Text("0时")
                Spacer()
                Text("6")
                Spacer()
                Text("12")
                Spacer()
                Text("18")
                Spacer()
                Text("24")
            }
            .font(.system(size: 9))
            .foregroundStyle(.tertiary)
            ForEach(0..<7, id: \.self) { row in
                HStack(spacing: 2) {
                    Text(["一", "二", "三", "四", "五", "六", "日"][row])
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .frame(width: 16, alignment: .leading)
                    ForEach(0..<24, id: \.self) { hour in
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(Color.primary
                                .opacity(peak > 0 ? 0.06 + (cells[row][hour] / peak) * 0.72 : 0.06))
                            .frame(maxWidth: .infinity)
                    }
                }
            }
        }
    }
}

private struct WorkoutJournalRow: View {
    let record: WorkoutRecord
    private var points: [WorkoutPacePoint] { workoutPacePoints(record.samples) }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(WorkoutText.time.string(from: record.startedAt))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Text(workoutDuration(record.endedAt.timeIntervalSince(record.startedAt)))
                    .font(.title3.weight(.semibold))
                    .monospacedDigit()
                Text(workoutJournalLine(record))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                if !record.songs.isEmpty {
                    HStack(spacing: -6) {
                        ForEach(record.songs.prefix(4)) { song in
                            WorkoutCover(url: song.coverURL, size: 22)
                                .overlay {
                                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                                        .strokeBorder(Color(.systemBackground), lineWidth: 1)
                                }
                        }
                        if record.songs.count > 4 {
                            Text("+\(record.songs.count - 4)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .padding(.leading, 10)
                        }
                    }
                    .padding(.top, 2)
                }
            }
            Spacer(minLength: 8)
            if points.count >= 2 {
                WorkoutPaceSpark(points: points)
                    .frame(width: 72, height: 28)
                    .padding(.top, 18)
            }
        }
        .padding(.leading, 14)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(Color.primary.opacity(0.12))
                .frame(width: 1)
        }
    }
}

private struct WorkoutRecordDetail: View {
    let record: WorkoutRecord
    private var points: [WorkoutPacePoint] { workoutPacePoints(record.samples) }
    private var splits: [WorkoutSplit] { workoutSplits(record.samples) }
    private var fastestKilometer: Int? { splits.min { $0.pace < $1.pace }?.kilometer }
    private var speedPoints: [WorkoutIntervalPoint] { workoutSpeedPoints(record.samples) }
    private var heartPoints: [WorkoutIntervalPoint] { workoutHeartPoints(record.samples) }
    private var cadencePoints: [WorkoutIntervalPoint] { workoutCadencePoints(record.samples) }
    private var energyPoints: [WorkoutIntervalPoint] { workoutEnergyPoints(record.samples) }

    private var fastestPace: WorkoutPacePoint? {
        if let fastest = points.min(by: { $0.pace < $1.pace }) { return fastest }
        if let pace = record.fastestPace {
            return WorkoutPacePoint(at: record.fastestPaceAt ?? record.endedAt, pace: pace)
        }
        return nil
    }

    private var peakHeart: WorkoutIntervalPoint? {
        if let peak = heartPoints.max(by: { $0.value < $1.value }) { return peak }
        if let heart = record.peakHeartRate {
            return WorkoutIntervalPoint(at: record.peakHeartRateAt ?? record.endedAt, value: heart)
        }
        return nil
    }

    private var peakCadence: WorkoutIntervalPoint? {
        cadencePoints.max { $0.value < $1.value }
    }

    private var peakEnergy: WorkoutIntervalPoint? {
        energyPoints.max { $0.value < $1.value }
    }

    private var fastestPaceCaption: String? {
        if let fastest = points.min(by: { $0.pace < $1.pace }) {
            return WorkoutText.time.string(from: fastest.at)
        }
        return record.fastestPace == nil ? nil : "来自健康记录"
    }

    private var peakHeartCaption: String? {
        if let peak = heartPoints.max(by: { $0.value < $1.value }) {
            return WorkoutText.time.string(from: peak.at)
        }
        return record.peakHeartRate == nil ? nil : "来自健康记录"
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                hero
                peakSection
                if points.count >= 2 {
                    paceSection
                }
                if !splits.isEmpty {
                    splitsSection
                }
                statsSection
                songsSection
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
        }
        .scrollIndicators(.hidden)
        .background(Color(.systemBackground).ignoresSafeArea())
        .navigationTitle(WorkoutSessionStore.Activity(rawValue: record.activity)?.title ?? "锻炼")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var hero: some View {
        WorkoutCard {
            VStack(spacing: 8) {
                Text(workoutClock(record.endedAt.timeIntervalSince(record.startedAt)))
                    .font(.system(size: 46, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text("\(WorkoutText.day.string(from: record.startedAt))  \(WorkoutText.time.string(from: record.startedAt)) – \(WorkoutText.time.string(from: record.endedAt))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(workoutHeadline(record))
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)
            .multilineTextAlignment(.center)
        }
    }

    private var peakSection: some View {
        WorkoutCard {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("峰值")
                        .font(.title3.weight(.semibold))
                    Spacer()
                    Text("约 15 秒采样")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 20) {
                    WorkoutPeakCell(title: "配速",
                                    value: fastestPace.flatMap { workoutPaceText($0.pace) } ?? "—",
                                    caption: fastestPaceCaption,
                                    points: speedPoints)
                    WorkoutPeakCell(title: "心率",
                                    value: peakHeart.map { "\(Int($0.value.rounded())) bpm" } ?? "—",
                                    caption: peakHeartCaption,
                                    points: heartPoints)
                    WorkoutPeakCell(title: "步频",
                                    value: peakCadence.map { "\(Int($0.value.rounded())) 步/分" } ?? "—",
                                    caption: peakCadence.map { WorkoutText.time.string(from: $0.at) },
                                    points: cadencePoints)
                    WorkoutPeakCell(title: "能量",
                                    value: peakEnergy.map { String(format: "%.1f 千卡/分", $0.value) } ?? "—",
                                    caption: peakEnergy.map { WorkoutText.time.string(from: $0.at) },
                                    points: energyPoints)
                }
            }
        }
    }

    private var paceSection: some View {
        WorkoutCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text("配速")
                        .font(.title3.weight(.semibold))
                    Spacer()
                    if let fastest = fastestPace, let pace = workoutPaceText(fastest.pace) {
                        Text("最快 \(pace) · \(WorkoutText.time.string(from: fastest.at))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                WorkoutPaceRiver(points: points)
                    .frame(height: 100)
                Text("越靠上越快")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var splitsSection: some View {
        WorkoutCard {
            VStack(alignment: .leading, spacing: 0) {
                Text("每公里")
                    .font(.title3.weight(.semibold))
                    .padding(.bottom, 12)
                ForEach(splits) { split in
                    HStack {
                        Text("第 \(split.kilometer) 公里")
                        Spacer()
                        Text(workoutPaceText(split.pace) ?? "—")
                            .monospacedDigit()
                        Text(WorkoutText.time.string(from: split.at))
                            .foregroundStyle(.secondary)
                            .frame(width: 48, alignment: .trailing)
                    }
                    .font(split.kilometer == fastestKilometer ? .subheadline.weight(.semibold) : .subheadline)
                    .padding(.vertical, 10)
                    .overlay(alignment: .bottom) {
                        Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 0.5)
                    }
                }
            }
        }
    }

    private var statsSection: some View {
        WorkoutCard {
            VStack(alignment: .leading, spacing: 16) {
                Text("统计")
                    .font(.title3.weight(.semibold))
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 18) {
                    ForEach(stats) { stat in
                        VStack(spacing: 4) {
                            Text(stat.value)
                                .font(.headline.weight(.semibold))
                                .monospacedDigit()
                                .lineLimit(1)
                                .minimumScaleFactor(0.65)
                            Text(stat.title)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .multilineTextAlignment(.center)
                    }
                }
            }
        }
    }

    private var songsSection: some View {
        WorkoutCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 6) {
                    Image(systemName: "music.note")
                        .font(.system(size: 15, weight: .semibold))
                    Text("这次听过")
                        .font(.system(size: 18, weight: .semibold))
                }
                if record.songs.isEmpty {
                    Text("这次没有记下歌曲")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(record.songs) { song in
                        HStack(spacing: 12) {
                            WorkoutCover(url: song.coverURL, size: 44)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(song.title).lineLimit(1)
                                Text("\(WorkoutText.time.string(from: song.playedAt)) · \(song.artist)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                }
            }
        }
    }

    private var stats: [WorkoutFact] {
        let length = record.endedAt.timeIntervalSince(record.startedAt)
        let minutes = length / 60
        var rows: [WorkoutFact] = []
        func add(_ title: String, _ value: String?) {
            rows.append(WorkoutFact(title: title, value: value ?? "—"))
        }
        add("时长", workoutDuration(length))
        add("距离", workoutMetersText(record.distance))
        add("步数", record.steps.map(String.init))
        add("平均配速", workoutPaceText(record.averagePace))
        add("最快配速", workoutPaceText(record.fastestPace))
        add("最慢配速", workoutPaceText(record.slowestPace))
        if let steps = record.steps, minutes >= 0.5 {
            add("步频", "\(Int((Double(steps) / minutes).rounded())) 步/分")
        } else {
            add("步频", nil)
        }
        if let steps = record.steps, let distance = record.distance, steps > 0 {
            add("步幅", String(format: "%.2f 米", distance / Double(steps)))
        } else {
            add("步幅", nil)
        }
        add("心率峰值", record.peakHeartRate.map { "\(Int($0.rounded())) bpm" })
        add("平均心率", record.averageHeartRate.map { "\(Int($0.rounded())) bpm" })
        add("能量", record.energy.map { "\(Int($0.rounded())) 千卡" })
        add("上楼", record.floors.map(String.init))
        add("下楼", record.floorsDescended.map(String.init))
        return rows
    }
}

private struct WorkoutPeakCell: View {
    let title: String
    let value: String
    let caption: String?
    let points: [WorkoutIntervalPoint]

    var body: some View {
        VStack(spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.headline.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.65)
            Text(caption ?? "没有逐点数据")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            WorkoutMiniBars(points: points)
                .frame(height: 30)
        }
        .frame(maxWidth: .infinity)
        .multilineTextAlignment(.center)
    }
}

private struct WorkoutMiniBars: View {
    let points: [WorkoutIntervalPoint]

    var body: some View {
        Canvas { context, size in
            let bars = workoutDownsample(points)
            guard bars.count >= 2 else {
                var line = Path()
                line.move(to: CGPoint(x: 0, y: size.height * 0.82))
                line.addLine(to: CGPoint(x: size.width, y: size.height * 0.82))
                context.stroke(line,
                               with: .color(Color.primary.opacity(0.08)),
                               style: StrokeStyle(lineWidth: 2, lineCap: .round))
                return
            }
            let maxValue = max(bars.map(\.value).max() ?? 0, 0.0001)
            let gap: CGFloat = 2
            let width = max((size.width - gap * CGFloat(bars.count - 1)) / CGFloat(bars.count), 1)
            for (index, point) in bars.enumerated() {
                let ratio = point.value / maxValue
                let height = max(size.height * CGFloat(ratio), 1.5)
                let rect = CGRect(x: CGFloat(index) * (width + gap),
                                  y: size.height - height,
                                  width: width,
                                  height: height)
                let isPeak = point.value >= maxValue * 0.999
                context.fill(Path(roundedRect: rect, cornerRadius: min(width / 2, 2)),
                             with: .color(isPeak ? Theme.accent : Color.primary.opacity(0.16 + ratio * 0.5)))
            }
        }
    }
}

private struct WorkoutIntervalPoint: Identifiable {
    let at: Date
    let value: Double
    var id: Date { at }
}

private func workoutDownsample(_ points: [WorkoutIntervalPoint], maxCount: Int = 32) -> [WorkoutIntervalPoint] {
    guard points.count > maxCount else { return points }
    let stride = Double(points.count) / Double(maxCount)
    return (0..<maxCount).compactMap { index in
        let start = Int(Double(index) * stride)
        let end = min(Int(Double(index + 1) * stride), points.count)
        guard start < end else { return nil }
        let slice = points[start..<end]
        let average = slice.map(\.value).reduce(0, +) / Double(slice.count)
        guard let last = slice.last else { return nil }
        return WorkoutIntervalPoint(at: last.at, value: average)
    }
}

private func workoutSpeedPoints(_ samples: [WorkoutSample]) -> [WorkoutIntervalPoint] {
    workoutPacePoints(samples).map {
        WorkoutIntervalPoint(at: $0.at, value: 1 / max($0.pace, 0.0001))
    }
}

private func workoutHeartPoints(_ samples: [WorkoutSample]) -> [WorkoutIntervalPoint] {
    samples.compactMap { sample in
        guard let heart = sample.heartRate else { return nil }
        return WorkoutIntervalPoint(at: sample.at, value: heart)
    }
}

private func workoutCadencePoints(_ samples: [WorkoutSample]) -> [WorkoutIntervalPoint] {
    let ordered = samples.sorted { $0.at < $1.at }
    var points: [WorkoutIntervalPoint] = []
    for pair in zip(ordered, ordered.dropFirst()) {
        guard let startSteps = pair.0.steps, let endSteps = pair.1.steps else { continue }
        let minutes = pair.1.at.timeIntervalSince(pair.0.at) / 60
        guard minutes > 0.05 else { continue }
        let cadence = Double(max(endSteps - startSteps, 0)) / minutes
        guard cadence > 20, cadence < 260 else { continue }
        points.append(WorkoutIntervalPoint(at: pair.1.at, value: cadence))
    }
    return points
}

private func workoutEnergyPoints(_ samples: [WorkoutSample]) -> [WorkoutIntervalPoint] {
    let ordered = samples.sorted { $0.at < $1.at }
    var points: [WorkoutIntervalPoint] = []
    var lastEnergy: Double?
    var lastEnergyAt: Date?
    for sample in ordered {
        guard let energy = sample.energy else { continue }
        if let last = lastEnergy, let lastAt = lastEnergyAt, energy > last {
            let minutes = sample.at.timeIntervalSince(lastAt) / 60
            if minutes > 0.1 {
                points.append(WorkoutIntervalPoint(at: sample.at, value: (energy - last) / minutes))
                lastEnergy = energy
                lastEnergyAt = sample.at
            }
        } else if lastEnergy == nil {
            lastEnergy = energy
            lastEnergyAt = sample.at
        }
    }
    return points
}

private struct WorkoutFact: Identifiable {
    let title: String
    let value: String
    var id: String { title }
}

private struct WorkoutPaceRiver: View {
    let points: [WorkoutPacePoint]

    var body: some View {
        Canvas { context, size in
            guard points.count >= 2 else { return }
            let paces = points.map(\.pace)
            let low = paces.min() ?? 1
            let high = max(paces.max() ?? low, low + 0.0001)
            func x(_ index: Int) -> CGFloat {
                CGFloat(index) / CGFloat(points.count - 1) * size.width
            }
            func y(_ pace: TimeInterval) -> CGFloat {
                let t = (pace - low) / (high - low)
                return size.height * (0.16 + CGFloat(t) * 0.72)
            }
            var line = Path()
            line.move(to: CGPoint(x: x(0), y: y(points[0].pace)))
            for index in points.indices.dropFirst() {
                line.addLine(to: CGPoint(x: x(index), y: y(points[index].pace)))
            }
            var fill = line
            fill.addLine(to: CGPoint(x: size.width, y: size.height))
            fill.addLine(to: CGPoint(x: 0, y: size.height))
            fill.closeSubpath()
            context.fill(fill, with: .color(Color.primary.opacity(0.06)))
            context.stroke(line, with: .color(Color.primary.opacity(0.85)),
                           style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
            if let fastest = points.enumerated().min(by: { $0.element.pace < $1.element.pace }) {
                let point = CGPoint(x: x(fastest.offset), y: y(fastest.element.pace))
                context.fill(Path(ellipseIn: CGRect(x: point.x - 3.5, y: point.y - 3.5, width: 7, height: 7)),
                             with: .color(Color.primary))
            }
        }
    }
}

private struct WorkoutPaceSpark: View {
    let points: [WorkoutPacePoint]

    var body: some View {
        Canvas { context, size in
            guard points.count >= 2 else { return }
            let paces = points.map(\.pace)
            let low = paces.min() ?? 1
            let high = max(paces.max() ?? low, low + 0.0001)
            var line = Path()
            for index in points.indices {
                let x = CGFloat(index) / CGFloat(points.count - 1) * size.width
                let y = size.height * CGFloat((points[index].pace - low) / (high - low))
                if index == 0 { line.move(to: CGPoint(x: x, y: y)) }
                else { line.addLine(to: CGPoint(x: x, y: y)) }
            }
            context.stroke(line, with: .color(Color.primary.opacity(0.7)),
                           style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round))
        }
    }
}

private struct WorkoutCover: View {
    let url: String?
    var size: CGFloat = 44

    var body: some View {
        CachedAsyncImage(url: url?.resizedImageURL(128)) {
            Image(systemName: "music.note")
                .font(.system(size: max(size * 0.36, 8), weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.primary.opacity(0.06))
        }
        .scaledToFill()
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
    }
}

private enum WorkoutSpan: Equatable {
    case week, month, custom
}

private struct WorkoutDay: Identifiable {
    let date: Date
    let records: [WorkoutRecord]
    var id: Date { date }

    static func groups(_ records: [WorkoutRecord]) -> [WorkoutDay] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: records) { calendar.startOfDay(for: $0.startedAt) }
        return grouped.keys.sorted(by: >).map { day in
            WorkoutDay(date: day, records: grouped[day, default: []].sorted { $0.startedAt > $1.startedAt })
        }
    }
}

private enum WorkoutText {
    static let day: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.setLocalizedDateFormatFromTemplate("MMMdEEE")
        return formatter
    }()

    static let time: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    static let shortDay: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.setLocalizedDateFormatFromTemplate("Md")
        return formatter
    }()
}

private func workoutClock(_ seconds: TimeInterval) -> String {
    let total = max(Int(seconds), 0)
    return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
}

private func workoutDuration(_ seconds: TimeInterval) -> String {
    let total = max(Int(seconds.rounded()), 0)
    if total >= 3600 { return String(format: "%d 小时 %d 分", total / 3600, (total % 3600) / 60) }
    return "\(max(total / 60, total > 0 ? 1 : 0)) 分钟"
}

private func workoutMetersText(_ value: Double?) -> String? {
    guard let value, value > 0 else { return nil }
    if value >= 1000 { return String(format: "%.2f 公里", value / 1000) }
    return "\(Int(value.rounded())) 米"
}

private func workoutPaceText(_ secondsPerMeter: TimeInterval?) -> String? {
    guard let secondsPerMeter, secondsPerMeter > 0 else { return nil }
    let perKilometer = Int((secondsPerMeter * 1000).rounded())
    return String(format: "%d'%02d\"", perKilometer / 60, perKilometer % 60)
}

private func workoutJournalLine(_ record: WorkoutRecord) -> String {
    var parts: [String] = []
    if let meters = workoutMetersText(record.distance) { parts.append(meters) }
    if let pace = workoutPaceText(record.fastestPace) { parts.append("最快 \(pace)") }
    else if let pace = workoutPaceText(record.averagePace) { parts.append("配速 \(pace)") }
    if let peak = record.peakHeartRate { parts.append("心率 \(Int(peak.rounded()))") }
    return parts.isEmpty ? "只记下了时长" : parts.joined(separator: " · ")
}

private func workoutHeadline(_ record: WorkoutRecord) -> String {
    let splits = workoutSplits(record.samples)
    if let fastest = splits.min(by: { $0.pace < $1.pace }), let pace = workoutPaceText(fastest.pace) {
        var line = "最快是第 \(fastest.kilometer) 公里，配速 \(pace)"
        if let half = workoutHalfSentence(record.samples) { line += "。\(half)" }
        return line
    }
    if let fastest = record.fastestPace, let pace = workoutPaceText(fastest) {
        var line = "最快配速 \(pace)"
        if let at = record.fastestPaceAt {
            line = "最快出现在 \(WorkoutText.time.string(from: at))，配速 \(pace)"
        }
        if let average = record.averagePace, average > fastest {
            let gap = Int(((average - fastest) / average * 100).rounded())
            if gap > 0 { line += "，比平均快 \(gap)%" }
        }
        return line
    }
    if let peak = record.peakHeartRate {
        var line = "心率最高 \(Int(peak.rounded()))"
        if let at = record.peakHeartRateAt {
            line += "，在 \(WorkoutText.time.string(from: at))"
        }
        return line
    }
    if let average = record.averagePace, let pace = workoutPaceText(average) {
        if let meters = workoutMetersText(record.distance) { return "平均配速 \(pace)，\(meters)" }
        return "平均配速 \(pace)"
    }
    return "这次只记下了总时长"
}

private func workoutHalfSentence(_ samples: [WorkoutSample]) -> String? {
    let ordered = samples.sorted { $0.at < $1.at }
    guard let first = ordered.first?.distance,
          let last = ordered.last?.distance,
          last - first >= 160,
          let end = ordered.last else { return nil }
    let mid = first + (last - first) / 2
    guard let middle = ordered.first(where: { ($0.distance ?? 0) >= mid }),
          let middleDistance = middle.distance else { return nil }
    let firstMeters = middleDistance - first
    let secondMeters = last - middleDistance
    let firstSeconds = middle.at.timeIntervalSince(ordered[0].at)
    let secondSeconds = end.at.timeIntervalSince(middle.at)
    guard firstMeters >= 80, secondMeters >= 80, firstSeconds > 20, secondSeconds > 20 else { return nil }
    let firstPace = firstSeconds / firstMeters
    let secondPace = secondSeconds / secondMeters
    let change = (firstPace - secondPace) / firstPace
    guard abs(change) >= 0.08 else { return nil }
    let percent = Int((abs(change) * 100).rounded())
    return change > 0 ? "后半程比前半程快 \(percent)%" : "后半程比前半程慢 \(percent)%"
}
#endif
