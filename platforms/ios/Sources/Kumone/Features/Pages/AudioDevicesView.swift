#if os(iOS)
import Foundation
import SwiftUI
import UIKit

/// 我的页面里的「音频设备」：按健康 App 的耳机音量记录统计各设备佩戴时长。
struct AudioDevicesView: View {
    @StateObject private var store = AudioDeviceStatsStore()
    @State private var range: AudioDeviceStatsStore.Range = .week
    @State private var showOutputInfo = false

    private var sessionTotal: Int { store.devices.reduce(0) { $0 + $1.sessionCount } }
    private var averageSession: TimeInterval {
        sessionTotal > 0 ? store.totalDuration / Double(sessionTotal) : 0
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                picker

                if !AudioDeviceStatsStore.isAvailable {
                    notice("这台设备不支持健康数据")
                } else if store.isLoading, store.devices.isEmpty {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.top, 40)
                } else if store.devices.isEmpty {
                    emptyState
                } else {
                    todayCard
                    heroCard
                    recordsSection
                    safetySection
                    deviceSection
                    recentSection
                }

                limitationNote
                credit
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 18)
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .navigationTitle("音频设备")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await store.load(range: range) }
        .task(id: range) { await store.load(range: range) }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                outputBadge
            }
        }
        .alert("当前音频输出", isPresented: $showOutputInfo) {
            Button("好", role: .cancel) {}
        } message: {
            Text("\(DeviceArtworkCatalog.displayName(for: currentOutput.name))\n\(currentOutput.detail)\n\(store.isAuthorized ? "健康数据已授权" : "健康数据未授权")")
        }
    }

    private var currentOutput: AudioRouteSnapshot {
        AudioRouteSnapshot.current()
    }

    private var outputSymbol: String {
        let name = currentOutput.name.lowercased()
        if name.contains("airpods") || name.contains("earpods") || name.contains("buds") {
            return "airpods"
        }
        if name.contains("speaker") || name.contains("iphone") || name.contains("ipad")
            || name.contains("扬声器") || name.contains("听筒") {
            return "speaker.wave.2"
        }
        return "headphones"
    }

    private var outputBadge: some View {
        Button { showOutputInfo = true } label: {
            ZStack(alignment: .topTrailing) {
                Image(systemName: outputSymbol)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 24, height: 24)
                Circle()
                    .fill(store.isAuthorized ? Color.green : Color.orange)
                    .frame(width: 7, height: 7)
                    .overlay { Circle().stroke(Color(.systemBackground), lineWidth: 1.5) }
            }
            .padding(3)
            .frame(width: 30, height: 30)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("当前音频输出")
    }

    private var picker: some View {
        Picker("范围", selection: $range) {
            ForEach(AudioDeviceStatsStore.Range.allCases) { item in
                Text(item.title).tag(item)
            }
        }
        .pickerStyle(.segmented)
    }

    private var todayCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("今天")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if let name = store.todayTopDevice, store.todayTopDuration > 0 {
                    Text("今天用得最多 · \(DeviceArtworkCatalog.displayName(for: name))")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }

            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(store.todayDuration > 0 ? audioDurationText(store.todayDuration) : "—")
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                        .monospacedDigit()
                    Text(store.todayDuration > 0 ? "今日佩戴时长" : "今天还没有佩戴记录")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if let name = store.todayTopDevice, store.todayTopDuration > 0 {
                    AudioArtworkStage(size: 56, radius: 16) {
                        HeadphoneArtworkView(name: name, inset: 5)
                    }
                }
            }

            if let name = store.todayTopDevice, store.todayDuration > 0 {
                let share = min(max(store.todayTopDuration / store.todayDuration, 0), 1)
                HStack(spacing: 10) {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.primary.opacity(0.07))
                            Capsule()
                                .fill(Theme.accent)
                                .frame(width: max(geo.size.width * share, 2))
                        }
                    }
                    .frame(height: 4)
                    Text("\(Int((share * 100).rounded()))%")
                        .font(.caption2.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(20)
        .audioCard()
    }

    private var heroCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text("聆听时长")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                HStack(spacing: 6) {
                    if store.currentStreak > 1 {
                        Text("连续 \(store.currentStreak) 天")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Theme.accent)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Theme.accent.opacity(0.12), in: Capsule())
                    }
                    trendBadge
                }
            }

            VStack(alignment: .leading, spacing: 5) {
                Text(audioDurationText(store.totalDuration))
                    .font(.system(size: 40, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Text("\(sessionTotal) 次佩戴 · \(store.activeDays) 天有记录")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("日均 \(audioDurationText(store.dailyAverage)) · 平均每次 \(audioDurationText(averageSession))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            AudioDailyBars(points: store.daily)
                .frame(height: 88)

            HStack {
                Text(chartTitle)
                Spacer()
                Text("每天聆听")
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
        .padding(20)
        .audioCard()
    }

    @ViewBuilder
    private var trendBadge: some View {
        if range != .all, store.previousDuration > 0, store.totalDuration > 0 {
            let change = (store.totalDuration - store.previousDuration) / store.previousDuration
            let up = change >= 0
            HStack(spacing: 3) {
                Image(systemName: up ? "arrow.up.right" : "arrow.down.right")
                    .font(.system(size: 9, weight: .bold))
                Text("\(abs(Int((change * 100).rounded())))%")
                    .font(.caption2.weight(.semibold))
                    .monospacedDigit()
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.primary.opacity(0.06), in: Capsule())
        }
    }

    private var recordsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            audioSectionTitle("本区间纪录")
            LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading),
                                GridItem(.flexible(), alignment: .leading)],
                      spacing: 18) {
                recordCell("单次最长", audioDurationText(store.longestSession))
                recordCell("单日最长", audioDurationText(store.longestDay))
                recordCell("最长连续", store.longestStreak > 0 ? "\(store.longestStreak) 天" : "—")
                recordCell("使用天数", "\(store.activeDays) 天")
                recordCell("日均", audioDurationText(store.dailyAverage))
                recordCell("佩戴次数", "\(store.sessionCount) 次")
            }
            .padding(20)
            .audioCard()
        }
    }

    private func recordCell(_ title: String, _ value: String) -> some View {
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

    private var safetySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            audioSectionTitle("音量")
            AudioSafetyPanel(buckets: store.loudBuckets,
                             volumePoints: store.volumeDaily,
                             loudDuration: store.loudDuration,
                             loudEvents: store.loudEvents,
                             average: store.averageDecibels,
                             peak: store.peakDecibels)
        }
    }

    private var deviceSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            audioSectionTitle("设备")
            VStack(spacing: 0) {
                ForEach(Array(store.devices.enumerated()), id: \.element.id) { index, device in
                    NavigationLink {
                        AudioDeviceDetailView(device: device)
                    } label: {
                        deviceRow(device)
                    }
                    .buttonStyle(.plain)
                    if index < store.devices.count - 1 {
                        Rectangle()
                            .fill(Color.primary.opacity(0.07))
                            .frame(height: 0.5)
                            .padding(.leading, 84)
                    }
                }
            }
            .padding(.vertical, 4)
            .audioCard()
        }
    }

    private func deviceRow(_ device: AudioDeviceStatsStore.Device) -> some View {
        HStack(spacing: 12) {
            Text(String(format: "%02d", device.rank))
                .font(.caption2.weight(.semibold).monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(width: 22, alignment: .leading)

            AudioArtworkStage(size: 52, radius: 15) {
                HeadphoneArtworkView(name: device.name, inset: 5)
            }

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(DeviceArtworkCatalog.displayName(for: device.name))
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    if device.rank == 1 {
                        Text("主力")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Theme.accent)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Theme.accent.opacity(0.12), in: Capsule())
                    }
                }
                Text("\(Int((device.share * 100).rounded()))% · 平均 \(audioVolumeText(device.averageDecibels))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.07))
                        Capsule()
                            .fill(Theme.accent)
                            .frame(width: max(geo.size.width * device.share, 2))
                    }
                }
                .frame(height: 3)
            }

            Text(audioDurationText(device.duration))
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .layoutPriority(1)

            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }

    private var recentSection: some View {
        let sessions = Array(store.recentSessions.prefix(7))
        return VStack(alignment: .leading, spacing: 10) {
            audioSectionTitle("最近佩戴")
            if sessions.isEmpty {
                Text("这个区间还没有佩戴记录")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
                    .audioCard()
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(sessions.enumerated()), id: \.element.id) { index, session in
                        AudioSessionRow(session: session)
                        if index < sessions.count - 1 {
                            Rectangle()
                                .fill(Color.primary.opacity(0.07))
                                .frame(height: 0.5)
                                .padding(.leading, 62)
                        }
                    }
                }
                .padding(.vertical, 4)
                .audioCard()
            }
        }
    }

    private var limitationNote: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("数据来自健康 App 的耳机音量记录，只在本机读取。")
            if let start = store.statisticsStart {
                Text("本次读取覆盖 \(AudioDateText.fullDay.string(from: start)) 至今。")
            }
            if let loaded = store.lastLoadedAt {
                Text("上次读取 \(audioDayText(loaded))。")
            }
        }
        .font(.caption2)
        .foregroundStyle(.tertiary)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var credit: some View {
        VStack(spacing: 5) {
            Text("灵感与部分源码来自 PodsStats")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text("由开发者 谭皓轩 提供")
            Text("开发者小红书账号：baikaihao")
        }
        .font(.caption2)
        .foregroundStyle(.tertiary)
        .frame(maxWidth: .infinity)
        .multilineTextAlignment(.center)
        .padding(.top, 20)
        .padding(.bottom, 28)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "airpods")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.secondary)
            Text("还没有耳机佩戴数据")
                .font(.headline)
            Text("在健康 App 里允许读取「耳机音量」后，这里会按设备统计佩戴时长。")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button {
                Task {
                    await store.requestAuthorization()
                    await store.load(range: range)
                }
            } label: {
                if store.isRequesting {
                    ProgressView()
                        .frame(minWidth: 160, minHeight: 28)
                } else {
                    Text("请求健康数据权限")
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.accent)
            .disabled(store.isRequesting)
            if let message = store.errorMessage {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 20)
        .padding(.top, 32)
    }

    private func notice(_ text: String) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.top, 40)
    }

    private var rangeTitle: String {
        switch range {
        case .week: return "近 7 天"
        case .month: return "近 30 天"
        case .all: return "累计"
        }
    }

    private var chartTitle: String {
        range == .all ? "近 30 天" : rangeTitle
    }
}

private struct AudioDeviceDetailView: View {
    let device: AudioDeviceStatsStore.Device
    @State private var maxColor: String
    @State private var earPodsConnector: String

    init(device: AudioDeviceStatsStore.Device) {
        self.device = device
        _maxColor = State(initialValue: HeadphoneArtwork.savedMaxColor(for: device.name))
        _earPodsConnector = State(initialValue: HeadphoneArtwork.savedEarPodsConnector(for: device.name))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                dailySection
                safetySection
                hourlySection
                recordsSection
                recentSection
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 18)
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .navigationTitle(DeviceArtworkCatalog.displayName(for: device.name))
        .navigationBarTitleDisplayMode(.inline)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 18) {
                AudioArtworkStage(size: 120, radius: 30) {
                    HeadphoneArtworkView(name: device.name,
                                         maxColor: maxColor,
                                         earPodsConnector: earPodsConnector,
                                         inset: 10)
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text(DeviceArtworkCatalog.displayName(for: device.name))
                        .font(.headline)
                        .lineLimit(2)
                    Text(audioDurationText(device.duration))
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    Text("\(Int((device.share * 100).rounded()))% 的佩戴时长 · \(device.sessionCount) 次")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("最近佩戴 \(audioDayText(device.lastUsed))")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
            }
            if case .max = HeadphoneKind.match(device.name) {
                maxColorPicker
            }
            if isEarPods {
                earPodsConnectorPicker
            }
        }
    }

    private var isEarPods: Bool {
        let lower = device.name.lowercased()
        return lower.contains("earpods") || lower.contains("earphones")
    }

    private var earPodsConnectorPicker: some View {
        HStack(spacing: 8) {
            Text("接口")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            ForEach(HeadphoneArtwork.earPodsConnectors) { option in
                Button {
                    earPodsConnector = option.id
                    HeadphoneArtwork.saveEarPodsConnector(option.id, for: device.name)
                } label: {
                    Text(option.name)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(earPodsConnector == option.id ? Color(.systemBackground) : .primary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(earPodsConnector == option.id
                                    ? Color.primary
                                    : Color.primary.opacity(0.08),
                                    in: Capsule())
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
    }

    private var maxColorPicker: some View {
        HStack(spacing: 10) {
            Text("颜色")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            ForEach(HeadphoneArtwork.maxColors) { option in
                Button {
                    maxColor = option.id
                    HeadphoneArtwork.saveMaxColor(option.id, for: device.name)
                } label: {
                    Circle()
                        .fill(audioMaxColor(option.id))
                        .frame(width: 20, height: 20)
                        .overlay {
                            Circle()
                                .strokeBorder(.white.opacity(maxColor == option.id ? 0.95 : 0), lineWidth: 2)
                        }
                        .overlay {
                            Circle()
                                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(option.name)
            }
            Spacer()
        }
    }

    private var dailySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                audioSectionTitle("每天聆听")
                Spacer()
                Text("统计区间同上")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            AudioDailyBars(points: device.daily)
                .frame(height: 84)
        }
        .padding(20)
        .audioCard()
    }

    private var safetySection: some View {
        AudioSafetyPanel(buckets: device.loudBuckets,
                         volumePoints: device.volumeDaily,
                         loudDuration: device.loudDuration,
                         loudEvents: device.loudEvents,
                         average: device.averageDecibels,
                         peak: device.peakDecibels)
    }

    private var hourlySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            audioSectionTitle("一天中的分布")
            AudioHourStrip(values: device.hourly)
                .frame(height: 56)
            HStack {
                Text("00")
                Spacer()
                Text("06")
                Spacer()
                Text("12")
                Spacer()
                Text("18")
                Spacer()
                Text("24")
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
            Text("最常佩戴 \(device.peakPeriod) · \(Int((device.peakShare * 100).rounded()))%")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .audioCard()
    }

    private var recordsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            audioSectionTitle("统计")
            LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading),
                                GridItem(.flexible(), alignment: .leading)],
                      spacing: 18) {
                statCell("平均每次", audioDurationText(device.averageSession))
                statCell("最长一次", audioDurationText(device.longestSession))
                statCell("单日最长", audioDurationText(device.dailyMax))
                statCell("使用天数", "\(device.daysUsed) 天")
                statCell("日均", audioDurationText(device.averagePerActiveDay))
                statCell("最长连续", device.longestStreak > 0 ? "\(device.longestStreak) 天" : "—")
                statCell("平均音量", audioVolumeText(device.averageDecibels))
                statCell("最高音量", audioVolumeText(device.peakDecibels))
                statCell("80 分贝以上", audioDurationText(device.loudDuration))
                statCell("音量提醒", "\(device.loudEvents) 次")
                statCell("工作日日均", audioDurationText(device.weekdayAverage))
                statCell("周末日均", audioDurationText(device.weekendAverage))
            }
        }
        .padding(20)
        .audioCard()
    }

    private func statCell(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
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

    private var recentSection: some View {
        let sessions = Array(device.sessions.suffix(8).reversed())
        return VStack(alignment: .leading, spacing: 10) {
            audioSectionTitle("最近佩戴")
            if sessions.isEmpty {
                Text("还没有佩戴记录")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
                    .audioCard()
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(sessions.enumerated()), id: \.element.id) { index, session in
                        AudioSessionRow(session: session, showDevice: false)
                        if index < sessions.count - 1 {
                            Rectangle()
                                .fill(Color.primary.opacity(0.07))
                                .frame(height: 0.5)
                                .padding(.leading, 44)
                        }
                    }
                }
                .padding(.vertical, 4)
                .audioCard()
            }
        }
    }
}

private struct AudioSessionRow: View {
    let session: AudioDeviceStatsStore.Session
    var showDevice = true

    var body: some View {
        HStack(spacing: 12) {
            if showDevice {
                AudioArtworkStage(size: 38, radius: 11) {
                    HeadphoneArtworkView(name: session.device, inset: 4)
                }
            } else {
                Circle()
                    .fill(Theme.accent)
                    .frame(width: 6, height: 6)
                    .frame(width: 12)
            }

            VStack(alignment: .leading, spacing: 3) {
                if showDevice {
                    Text(session.device)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                }
                Text("\(audioDayText(session.start)) – \(AudioDateText.clock.string(from: session.end))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 3) {
                Text(audioDurationText(session.duration))
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                Text(audioVolumeText(session.decibels))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }
}

/// 安全音量面板：平均音量、80 分贝以上占比、四档分布、音量趋势和高音量提醒。
private struct AudioSafetyPanel: View {
    let buckets: [TimeInterval]
    var volumePoints: [AudioDeviceStatsStore.VolumePoint] = []
    let loudDuration: TimeInterval
    let loudEvents: Int
    let average: Double?
    let peak: Double?

    private var total: TimeInterval { buckets.reduce(0, +) }
    private var loudShare: Double {
        guard total > 0, buckets.count > 3 else { return 0 }
        return (buckets[2] + buckets[3]) / total
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("平均音量")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(audioVolumeText(average))
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                        .monospacedDigit()
                    Text("峰值 \(audioVolumeText(peak))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                AudioLoudRing(share: loudShare)
            }

            AudioLoudStackedBar(buckets: buckets)

            HStack(spacing: 14) {
                legend("＜70", opacity: 0.18)
                legend("70–80", opacity: 0.38)
                legend("80–90", opacity: 0.62)
                legend("90+", opacity: 0.9)
            }

            if volumePoints.contains(where: { $0.decibels != nil }) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("音量趋势")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("虚线 80 dB")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    AudioVolumeTrend(points: volumePoints)
                        .frame(height: 54)
                }
            }

            HStack {
                Text("80 分贝以上 \(audioDurationText(loudDuration))")
                Spacer()
                Text("提醒 \(loudEvents) 次")
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
        .padding(20)
        .audioCard()
    }

    private func legend(_ text: String, opacity: Double) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(Color.primary.opacity(opacity))
                .frame(width: 6, height: 6)
            Text(text)
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }
}

private struct AudioVolumeTrend: View {
    let points: [AudioDeviceStatsStore.VolumePoint]

    var body: some View {
        Canvas { context, size in
            let values = points.compactMap(\.decibels)
            guard points.count >= 2, values.count >= 2 else { return }
            let low = max((values.min() ?? 50) - 4, 40)
            let high = min((values.max() ?? 90) + 4, 110)
            let span = max(high - low, 1)

            func x(_ index: Int) -> CGFloat {
                CGFloat(index) / CGFloat(points.count - 1) * size.width
            }
            func y(_ decibels: Double) -> CGFloat {
                size.height * CGFloat(1 - (decibels - low) / span)
            }

            if low < 80, high > 80 {
                var threshold = Path()
                threshold.move(to: CGPoint(x: 0, y: y(80)))
                threshold.addLine(to: CGPoint(x: size.width, y: y(80)))
                context.stroke(threshold,
                               with: .color(Color.primary.opacity(0.18)),
                               style: StrokeStyle(lineWidth: 0.8, dash: [3, 3]))
            }

            var line = Path()
            var started = false
            for (index, point) in points.enumerated() {
                guard let decibels = point.decibels else {
                    started = false
                    continue
                }
                let location = CGPoint(x: x(index), y: y(decibels))
                if started {
                    line.addLine(to: location)
                } else {
                    line.move(to: location)
                    started = true
                }
            }
            context.stroke(line,
                           with: .color(Theme.accent.opacity(0.85)),
                           style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
        }
    }
}

private struct AudioLoudRing: View {
    let share: Double

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.primary.opacity(0.08), lineWidth: 6)
            Circle()
                .trim(from: 0, to: CGFloat(min(max(share, 0), 1)))
                .stroke(Theme.accent, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("\(Int((min(max(share, 0), 1) * 100).rounded()))%")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .monospacedDigit()
        }
        .frame(width: 62, height: 62)
        .accessibilityLabel("80 分贝以上占比")
    }
}

private struct AudioLoudStackedBar: View {
    let buckets: [TimeInterval]

    var body: some View {
        GeometryReader { geo in
            let total = max(buckets.reduce(0, +), 0.0001)
            let visible = buckets.indices.filter { buckets[$0] > 0 }
            let gap = CGFloat(max(visible.count - 1, 0)) * 2
            let available = max(geo.size.width - gap, 0)
            HStack(spacing: 2) {
                ForEach(visible, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(Color.primary.opacity(audioLoudOpacity(index)))
                        .frame(width: max(available * CGFloat(buckets[index] / total), 2))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: 8)
        .background(Color.primary.opacity(0.06), in: Capsule())
        .clipShape(Capsule())
    }
}

private struct AudioDailyBars: View {
    let points: [AudioDeviceStatsStore.DailyPoint]

    var body: some View {
        Canvas { context, size in
            guard !points.isEmpty else { return }
            let maxValue = max(points.map(\.duration).max() ?? 0, 1)
            let gap: CGFloat = points.count > 14 ? 1.5 : 4
            let width = max((size.width - gap * CGFloat(points.count - 1)) / CGFloat(points.count), 1)
            for (index, point) in points.enumerated() {
                let ratio = point.duration / maxValue
                let height = max(size.height * CGFloat(ratio), point.duration > 0 ? 3 : 2)
                let rect = CGRect(x: CGFloat(index) * (width + gap),
                                  y: size.height - height,
                                  width: width,
                                  height: height)
                let path = Path(roundedRect: rect, cornerRadius: min(width / 2, 3))
                context.fill(path, with: .color(point.duration > 0
                                                ? Theme.accent.opacity(0.85)
                                                : Color.primary.opacity(0.12)))
            }
        }
    }
}

private struct AudioHourStrip: View {
    let values: [TimeInterval]

    var body: some View {
        Canvas { context, size in
            guard !values.isEmpty else { return }
            let maxValue = max(values.max() ?? 0, 1)
            let gap: CGFloat = 2
            let width = max((size.width - gap * CGFloat(values.count - 1)) / CGFloat(values.count), 1)
            for (index, value) in values.enumerated() {
                let ratio = CGFloat(value / maxValue)
                let height = max(ratio * size.height, value > 0 ? 2 : 1)
                let rect = CGRect(x: CGFloat(index) * (width + gap),
                                  y: size.height - height,
                                  width: width,
                                  height: height)
                let opacity = value > 0 ? 0.18 + Double(ratio) * 0.72 : 0.06
                context.fill(Path(roundedRect: rect, cornerRadius: width / 2),
                             with: .color(Color.primary.opacity(opacity)))
            }
        }
    }
}

/// 设备图容器。浅色底让午夜色这类深色耳机在深色模式里也能看清。
private struct AudioArtworkStage<Content: View>: View {
    let size: CGFloat
    let radius: CGFloat
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .frame(width: size, height: size)
            .background {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(
                        LinearGradient(colors: [Color.primary.opacity(0.03), Color.primary.opacity(0.08)],
                                       startPoint: .top, endPoint: .bottom)
                    )
            }
            .overlay(alignment: .top) {
                // 死图做不了真 3D，用顶部高光和轻微透视做出立体感。
                LinearGradient(colors: [.white.opacity(0.28), .clear],
                               startPoint: .top, endPoint: .center)
                    .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
                    .allowsHitTesting(false)
            }
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
            }
            .rotation3DEffect(.degrees(7), axis: (x: 1, y: -0.25, z: 0), perspective: 0.45)
            .shadow(color: .black.opacity(0.16), radius: size * 0.08, y: size * 0.045)
    }
}

private struct HeadphoneArtworkView: View {
    let name: String
    var maxColor: String? = nil
    var earPodsConnector: String? = nil
    var inset: CGFloat = 6

    var body: some View {
        if let image = HeadphoneArtwork.image(for: name,
                                              maxColor: maxColor,
                                              earPodsConnector: earPodsConnector) {
            image
                .resizable()
                .scaledToFit()
                .padding(inset)
        } else {
            Image(systemName: HeadphoneArtwork.fallbackSymbol(for: name))
                .font(.system(size: max(inset * 3.2, 12), weight: .regular))
                .foregroundStyle(.secondary)
        }
    }
}

/// 按健康记录里的型号名匹配原创设备图。
enum HeadphoneArtwork {
    struct MaxColorOption: Identifiable {
        let id: String
        let name: String
    }

    struct EarPodsConnectorOption: Identifiable {
        let id: String
        let name: String
    }

    static let maxColors: [MaxColorOption] = [
        MaxColorOption(id: "midnight", name: "午夜色"),
        MaxColorOption(id: "starlight", name: "星光色"),
        MaxColorOption(id: "blue", name: "蓝色"),
        MaxColorOption(id: "purple", name: "紫色"),
        MaxColorOption(id: "orange", name: "橙色"),
    ]

    static let earPodsConnectors: [EarPodsConnectorOption] = [
        EarPodsConnectorOption(id: "usbc", name: "USB-C"),
        EarPodsConnectorOption(id: "lightning", name: "Lightning"),
        EarPodsConnectorOption(id: "35mm", name: "3.5mm"),
    ]

    static func image(for name: String,
                      maxColor: String? = nil,
                      earPodsConnector: String? = nil) -> Image? {
        guard let asset = assetName(for: name,
                                    maxColor: maxColor,
                                    earPodsConnector: earPodsConnector),
              UIImage(named: asset, in: .main, compatibleWith: nil) != nil else { return nil }
        return Image(asset, bundle: .main)
    }

    static func assetName(for name: String,
                          maxColor: String? = nil,
                          earPodsConnector: String? = nil) -> String? {
        let lower = name.lowercased()
        if lower.contains("earpods") || lower.contains("earphones") {
            if lower.contains("3.5") || lower.contains("headphone plug") { return "earpods-35mm" }
            if lower.contains("lightning") { return "earpods-lightning" }
            if lower.contains("usb-c") || lower.contains("usb c")
                || lower.contains("type-c") || lower.contains("typec") {
                return "earpods-usbc"
            }
            return "earpods-\(earPodsConnector ?? savedEarPodsConnector(for: name))"
        }
        if lower.contains("airpods") {
            if lower.contains("max") {
                return "airpods-max-\(maxColor ?? savedMaxColor(for: name))"
            }
            if lower.contains("pro") {
                switch generation(in: lower) {
                case 3: return "airpods-pro-3"
                case 2: return "airpods-pro-2"
                default: return "airpods-pro-1"
                }
            }
            let generation = generation(in: lower)
            if generation == 5, lower.contains("无线") || lower.contains("wireless") {
                return "airpods-5-wireless"
            }
            switch generation {
            case 2: return "airpods-2"
            case 3: return "airpods-3"
            case 4: return "airpods-4"
            case 5: return "airpods-5"
            default: return "airpods-2"
            }
        }
        return DeviceArtworkCatalog.assetName(for: name)
    }

    static func fallbackSymbol(for name: String) -> String {
        switch HeadphoneKind.match(name) {
        case .speaker: return "hifispeaker"
        case .pro, .buds: return "airpods"
        default: return "headphones"
        }
    }

    static func savedMaxColor(for name: String) -> String {
        UserDefaults.standard.string(forKey: maxColorKey(name)) ?? "midnight"
    }

    static func saveMaxColor(_ color: String, for name: String) {
        UserDefaults.standard.set(color, forKey: maxColorKey(name))
    }

    static func savedEarPodsConnector(for name: String) -> String {
        UserDefaults.standard.string(forKey: earPodsKey(name)) ?? "usbc"
    }

    static func saveEarPodsConnector(_ connector: String, for name: String) {
        UserDefaults.standard.set(connector, forKey: earPodsKey(name))
    }

    private static func maxColorKey(_ name: String) -> String {
        "moumusic.airpodsMaxColor.\(name)"
    }

    private static func earPodsKey(_ name: String) -> String {
        "moumusic.earpodsConnector.\(name)"
    }

    private static func generation(in name: String) -> Int? {
        let patterns = [
            "(?<![0-9])([1-5])(?:st|nd|rd|th)\\s*generation",
            "第\\s*([1-5])\\s*代",
            "(?<![0-9])([1-5])(?![0-9])",
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                  let match = regex.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)),
                  let range = Range(match.range(at: 1), in: name),
                  let value = Int(name[range]) else { continue }
            return value
        }
        return nil
    }
}

private func audioSectionTitle(_ text: String) -> some View {
    Text(text)
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
}

private func audioLoudOpacity(_ index: Int) -> Double {
    switch index {
    case 0: return 0.18
    case 1: return 0.38
    case 2: return 0.62
    default: return 0.9
    }
}

private func audioDurationText(_ seconds: TimeInterval) -> String {
    let total = max(Int(seconds), 0)
    let hours = total / 3600
    let minutes = (total % 3600) / 60
    if hours > 0 { return "\(hours) 小时 \(minutes) 分" }
    return "\(minutes) 分钟"
}

private func audioVolumeText(_ decibels: Double?) -> String {
    guard let decibels, decibels.isFinite else { return "—" }
    return "\(Int(decibels.rounded())) dB"
}

private func audioDayText(_ date: Date?) -> String {
    guard let date else { return "—" }
    if Calendar.current.isDateInToday(date) {
        return "今天 \(AudioDateText.clock.string(from: date))"
    }
    return "\(AudioDateText.monthDay.string(from: date)) \(AudioDateText.clock.string(from: date))"
}

private func audioMaxColor(_ id: String) -> Color {
    switch id {
    case "blue": return Color(red: 0.55, green: 0.66, blue: 0.79)
    case "purple": return Color(red: 0.61, green: 0.57, blue: 0.72)
    case "orange": return Color(red: 0.84, green: 0.48, blue: 0.29)
    case "starlight": return Color(red: 0.90, green: 0.87, blue: 0.80)
    default: return Color(red: 0.14, green: 0.15, blue: 0.18)
    }
}

private enum AudioDateText {
    static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    static let monthDay: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日"
        return formatter
    }()

    static let fullDay: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy年M月d日"
        return formatter
    }()
}

/// 按健康记录里的型号名匹配轮廓。这是自己画的示意图，不是官网产品图。
enum HeadphoneKind {
    case max
    case pro
    case buds
    case overEar
    case speaker

    static func match(_ name: String) -> HeadphoneKind {
        let lower = name.lowercased()
        if lower.contains("max") { return .max }
        if lower.contains("speaker") || lower.contains("soundlink")
            || lower.contains("音箱") || lower.contains("jbl")
            || lower.contains("iphone") || lower.contains("ipad")
            || lower.contains("扬声器") || lower.contains("听筒")
            || lower.contains("receiver") {
            return .speaker
        }
        if lower.contains("pro") { return .pro }
        if lower.contains("airpods") || lower.contains("earpods")
            || lower.contains("buds") || lower.contains("freebuds") {
            return .buds
        }
        return .overEar
    }
}

struct HeadphoneGlyph: View {
    let kind: HeadphoneKind

    var body: some View {
        Canvas { context, size in
            let stroke = StrokeStyle(lineWidth: max(2.2, size.width * 0.045), lineCap: .round, lineJoin: .round)
            switch kind {
            case .max:
                drawMax(&context, size, stroke)
            case .pro:
                drawBuds(&context, size, stroke, stem: 0.42)
            case .buds:
                drawBuds(&context, size, stroke, stem: 0.72)
            case .overEar:
                drawOverEar(&context, size, stroke)
            case .speaker:
                drawSpeaker(&context, size, stroke)
            }
        }
    }

    private func drawMax(_ context: inout GraphicsContext, _ size: CGSize, _ stroke: StrokeStyle) {
        var band = Path()
        band.move(to: CGPoint(x: size.width * 0.18, y: size.height * 0.62))
        band.addQuadCurve(to: CGPoint(x: size.width * 0.82, y: size.height * 0.62),
                          control: CGPoint(x: size.width * 0.5, y: size.height * 0.02))
        context.stroke(band, with: .foreground, style: stroke)
        for x in [0.12, 0.70] {
            let cup = CGRect(x: size.width * x, y: size.height * 0.42,
                             width: size.width * 0.18, height: size.height * 0.48)
            context.stroke(Path(roundedRect: cup, cornerRadius: size.width * 0.08),
                           with: .foreground, style: stroke)
        }
    }

    private func drawBuds(_ context: inout GraphicsContext, _ size: CGSize,
                          _ stroke: StrokeStyle, stem: CGFloat) {
        for side in [0.08, 0.54] {
            let bud = CGRect(x: size.width * side, y: size.height * 0.08,
                             width: size.width * 0.34, height: size.height * 0.42)
            context.stroke(Path(ellipseIn: bud), with: .foreground, style: stroke)
            var stick = Path()
            stick.move(to: CGPoint(x: size.width * (side + 0.17), y: size.height * 0.46))
            stick.addLine(to: CGPoint(x: size.width * (side + 0.17),
                                      y: size.height * (0.46 + stem * 0.5)))
            context.stroke(stick, with: .foreground, style: stroke)
        }
    }

    private func drawOverEar(_ context: inout GraphicsContext, _ size: CGSize, _ stroke: StrokeStyle) {
        var band = Path()
        band.move(to: CGPoint(x: size.width * 0.22, y: size.height * 0.48))
        band.addQuadCurve(to: CGPoint(x: size.width * 0.78, y: size.height * 0.48),
                          control: CGPoint(x: size.width * 0.5, y: 0))
        context.stroke(band, with: .foreground, style: stroke)
        for x in [0.10, 0.68] {
            let cup = CGRect(x: size.width * x, y: size.height * 0.36,
                             width: size.width * 0.22, height: size.height * 0.5)
            context.stroke(Path(ellipseIn: cup), with: .foreground, style: stroke)
        }
    }

    private func drawSpeaker(_ context: inout GraphicsContext, _ size: CGSize, _ stroke: StrokeStyle) {
        let body = CGRect(x: size.width * 0.28, y: size.height * 0.08,
                          width: size.width * 0.44, height: size.height * 0.84)
        context.stroke(Path(roundedRect: body, cornerRadius: size.width * 0.08),
                       with: .foreground, style: stroke)
        let top = CGRect(x: size.width * 0.42, y: size.height * 0.20,
                         width: size.width * 0.16, height: size.height * 0.16)
        context.stroke(Path(ellipseIn: top), with: .foreground, style: stroke)
        let bottom = CGRect(x: size.width * 0.38, y: size.height * 0.52,
                            width: size.width * 0.24, height: size.height * 0.24)
        context.stroke(Path(ellipseIn: bottom), with: .foreground, style: stroke)
    }
}

private struct AudioCardModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .mouMaterialBackground(.ultraThinMaterial,
                                   in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(.white.opacity(0.12), lineWidth: 1)
            }
    }
}

private extension View {
    func audioCard() -> some View {
        modifier(AudioCardModifier())
    }
}
#endif
