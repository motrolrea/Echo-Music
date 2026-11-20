#if os(iOS)
import SwiftUI
import UIKit

/// 设置里的「音频设备」：按健康 App 的耳机音量记录统计各设备佩戴时长。
struct AudioDevicesView: View {
    @StateObject private var store = AudioDeviceStatsStore()
    @State private var range: AudioDeviceStatsStore.Range = .week

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Picker("范围", selection: $range) {
                    ForEach(AudioDeviceStatsStore.Range.allCases) { item in
                        Text(item.title).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)

                content
            }
            .padding(.vertical, 16)
        }
        .navigationTitle("音频设备")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: range) { await store.load(range: range) }
    }

    @ViewBuilder
    private var content: some View {
        if !AudioDeviceStatsStore.isAvailable {
            notice("这台设备不支持健康数据")
        } else if store.isLoading, store.devices.isEmpty {
            ProgressView()
                .frame(maxWidth: .infinity)
                .padding(.top, 40)
        } else if store.devices.isEmpty {
            emptyState
        } else {
            totalHeader
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(store.devices) { device in
                        deviceCard(device)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
        }
    }

    private var totalHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("总佩戴时长")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(durationText(store.totalDuration))
                .font(.system(size: 34, weight: .bold, design: .rounded))
                .monospacedDigit()
        }
        .padding(.horizontal, 20)
    }

    private func deviceCard(_ device: AudioDeviceStatsStore.Device) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.white.opacity(0.06))
                Image(systemName: glyph(for: device.name))
                    .font(.system(size: 44, weight: .light))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.white.opacity(0.86))
            }
            .frame(height: 92)
            .rotation3DEffect(.degrees(-8), axis: (x: 1, y: 1, z: 0), perspective: 0.6)

            Text(device.name)
                .font(.system(size: 14, weight: .semibold))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            Text(durationText(device.duration))
                .font(.system(size: 26, weight: .bold, design: .rounded))
                .monospacedDigit()

            Text("\(Int((device.share * 100).rounded()))% 的佩戴时长")
                .font(.caption)
                .foregroundStyle(.secondary)

            ProgressView(value: device.share)
                .tint(Theme.accent)
        }
        .padding(16)
        .frame(width: 210, alignment: .leading)
        .mouMaterialBackground(.ultraThinMaterial,
                               in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(.white.opacity(0.14), lineWidth: 1)
        }
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
        .padding(.horizontal, 32)
        .padding(.top, 40)
    }

    private func notice(_ text: String) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.top, 40)
    }

    private func durationText(_ seconds: TimeInterval) -> String {
        let total = max(Int(seconds), 0)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        if hours > 0 { return "\(hours) 小时 \(minutes) 分" }
        return "\(minutes) 分钟"
    }

    private func glyph(for name: String) -> String {
        let lower = name.lowercased()
        let candidates: [String]
        if lower.contains("max") {
            candidates = ["airpodsmax", "headphones"]
        } else if lower.contains("pro") {
            candidates = ["airpodspro", "airpods", "headphones"]
        } else if lower.contains("airpods") {
            candidates = ["airpods", "headphones"]
        } else if lower.contains("beats") {
            candidates = ["beats.headphones", "headphones"]
        } else {
            candidates = ["headphones"]
        }
        return candidates.first { UIImage(systemName: $0) != nil } ?? "headphones"
    }
}
#endif
