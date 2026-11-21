#if os(iOS)
import SwiftUI

/// Apple Fitness 风格的听歌锻炼页。数字只来自这次手动开始的检测。
struct WorkoutView: View {
    @EnvironmentObject private var player: PlayerService
    @StateObject private var session = WorkoutSessionStore()

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.07, green: 0.07, blue: 0.08), .black],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    activityPicker
                    timerBlock
                    metrics
                    songs
                    action
                }
                .padding(20)
            }
        }
        .navigationTitle("锻炼")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
    }

    private var activityPicker: some View {
        HStack(spacing: 10) {
            ForEach(WorkoutSessionStore.Activity.allCases) { item in
                Button {
                    session.select(item)
                } label: {
                    VStack(spacing: 6) {
                        Image(systemName: item.symbol)
                            .font(.system(size: 18, weight: .semibold))
                        Text(item.title)
                            .font(.caption.weight(.semibold))
                    }
                    .frame(maxWidth: .infinity, minHeight: 64)
                    .foregroundStyle(session.activity == item ? .black : .white)
                    .background(session.activity == item ? Color.green : Color.white.opacity(0.08),
                                in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(session.isRunning)
            }
        }
    }

    private var timerBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(session.activity.title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.green)
            Text(clock(session.elapsed))
                .font(.system(size: 64, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white)
            Text(session.status)
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.55))
        }
    }

    private var metrics: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            ring("步数", value: session.steps.map(String.init), tint: .green)
            ring("距离", value: meters(session.distance), tint: .cyan)
            ring("配速", value: pace(session.pace), tint: .yellow)
            ring("楼层", value: session.floors.map { "\($0)" }, tint: .orange)
            ring("心率", value: session.heartRate.map { "\(Int($0.rounded()))" }, tint: .pink)
            ring("能量", value: session.activeEnergy.map { "\(Int($0.rounded()))" }, tint: .red)
        }
    }

    private func ring(_ title: String, value: String?, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(value ?? "—")
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white)
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(tint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var songs: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("这次听过")
                .font(.headline)
                .foregroundStyle(.white)
            if session.songs.isEmpty {
                Text(session.isRunning ? "切歌后会出现在这里" : "开始后记录播放过的歌")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.5))
            } else {
                ForEach(session.songs) { song in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(song.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        Text(song.artist)
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.55))
                            .lineLimit(1)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var action: some View {
        Button {
            if session.isRunning {
                Task { await session.stop() }
            } else {
                session.start(player: player)
            }
        } label: {
            Text(session.isRunning ? "结束" : "开始")
                .font(.headline)
                .foregroundStyle(session.isRunning ? .white : .black)
                .frame(maxWidth: .infinity, minHeight: 54)
                .background(session.isRunning ? Color.red : Color.green,
                            in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private func clock(_ seconds: TimeInterval) -> String {
        let total = max(Int(seconds), 0)
        return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }

    private func meters(_ value: Double?) -> String? {
        guard let value else { return nil }
        if value >= 1000 { return String(format: "%.2f km", value / 1000) }
        return "\(Int(value.rounded())) m"
    }

    private func pace(_ secondsPerMeter: TimeInterval?) -> String? {
        guard let secondsPerMeter, secondsPerMeter > 0 else { return nil }
        let perKilometer = Int((secondsPerMeter * 1000).rounded())
        return String(format: "%d'%02d\"", perKilometer / 60, perKilometer % 60)
    }
}
#endif
