#if os(iOS)
import SwiftUI

/// 听歌锻炼。底栏收起，右上角只留一张旋转封面。
struct WorkoutView: View {
    @EnvironmentObject private var player: PlayerService
    @Environment(\.colorScheme) private var colorScheme
    @StateObject private var session = WorkoutSessionStore()
    @State private var focus: WorkoutSessionStore.Activity = .walk

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                modeSwitcher
                focusedHeader
                liveSession
                WorkoutPatternCard(activity: focus, records: session.records)
            }
            .padding(.horizontal, 22)
            .padding(.top, 8)
            .padding(.bottom, 36)
            .animation(.spring(response: 0.42, dampingFraction: 0.86), value: focus)
        }
        .scrollIndicators(.hidden)
        .background(Color(.systemBackground).ignoresSafeArea())
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
                metric("楼层", session.floors.map { "\($0)" })
                metric("心率", session.heartRate.map { "\(Int($0.rounded()))" })
                metric("能量", session.activeEnergy.map { "\(Int($0.rounded())) 千卡" })
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("这次听过")
                    .font(.subheadline.weight(.semibold))
                if session.songs.isEmpty {
                    Text(session.isRunning ? "切歌后记在这里" : "开始后记录播放过的歌")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(session.songs) { song in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(song.title).lineLimit(1)
                            Text(song.artist)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
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
        }
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
}

/// 近 7 天的锻炼分布：最常时段、一天中的高峰、星期热力、工作日和周末。
private struct WorkoutPatternCard: View {
    let activity: WorkoutSessionStore.Activity
    let records: [WorkoutRecord]

    private var recent: [WorkoutRecord] {
        let start = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? .distantPast
        return records.filter { $0.activity == activity.rawValue && $0.endedAt >= start && $0.endedAt > $0.startedAt }
    }

    var body: some View {
        let stats = PatternStats(records: recent)
        VStack(alignment: .leading, spacing: 18) {
            Text("近 7 天")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(stats.peakPeriod)
                .font(.system(size: 28, weight: .semibold, design: .rounded))
            Text(stats.shareText)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            WorkoutClock(hours: stats.hours, peakHour: stats.peakHour)
                .frame(height: 180)
                .frame(maxWidth: .infinity)

            WorkoutHeatmap(cells: stats.cells)
                .frame(height: 132)

            HStack(alignment: .top) {
                averageColumn("周中日均", stats.weekday)
                Spacer(minLength: 16)
                averageColumn("周末日均", stats.weekend)
            }
        }
        .padding(18)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private func averageColumn(_ title: String, _ value: TimeInterval) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value > 0 ? durationText(value) : "—")
                .font(.title3.weight(.semibold))
                .monospacedDigit()
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func durationText(_ seconds: TimeInterval) -> String {
        let total = max(Int(seconds.rounded()), 0)
        if total >= 3600 { return String(format: "%d 小时 %d 分", total / 3600, (total % 3600) / 60) }
        return "\(max(total / 60, total > 0 ? 1 : 0)) 分钟"
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
        shareText = total > 0 ? "这个时段占了近 7 天锻炼时长的 \(share)%" : "结束一次锻炼后，这里才开始统计"
        weekday = weekdayDays.isEmpty ? 0 : weekdayTotal / Double(weekdayDays.count)
        weekend = weekendDays.isEmpty ? 0 : weekendTotal / Double(weekendDays.count)
    }
}

private struct WorkoutClock: View {
    let hours: [Double]
    let peakHour: Int

    var body: some View {
        let peak = hours.max() ?? 0
        Canvas { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let radius = min(size.width, size.height) * 0.36
            for hour in 0..<24 {
                let angle = CGFloat(hour) / 24 * .pi * 2 - .pi / 2
                let strength = peak > 0 ? hours[hour] / peak : 0
                var line = Path()
                line.move(to: CGPoint(x: center.x + cos(angle) * radius * 0.72,
                                       y: center.y + sin(angle) * radius * 0.72))
                line.addLine(to: CGPoint(x: center.x + cos(angle) * radius,
                                          y: center.y + sin(angle) * radius))
                context.stroke(line,
                               with: .color(Color(red: 0.92, green: 0.42, blue: 0.18).opacity(0.18 + strength * 0.82)),
                               style: StrokeStyle(lineWidth: hour == peakHour && peak > 0 ? 3 : 1.6, lineCap: .round))
            }
        }
        .overlay {
            VStack(spacing: 2) {
                Text(hours.max() ?? 0 > 0 ? "\(peakHour) 点" : "—")
                    .font(.title2.weight(.semibold))
                Text("一天中的高峰")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
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
                Text("0")
                Spacer()
                Text("12")
                Spacer()
                Text("23")
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
                        RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                            .fill(Color(red: 0.92, green: 0.42, blue: 0.18)
                                .opacity(peak > 0 ? 0.08 + (cells[row][hour] / peak) * 0.92 : 0.08))
                            .frame(maxWidth: .infinity)
                    }
                }
            }
        }
    }
}
#endif
