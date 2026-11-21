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

                currentOutputCard
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

    /// 当前输出只能从系统音频路由读到名称、类型和声道，读不到单耳、左右耳和耳机仓电量。
    private var currentOutputCard: some View {
        let output = AudioRouteSnapshot.current()
        return VStack(alignment: .leading, spacing: 8) {
            Text("当前输出")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Image(systemName: glyph(for: output.name))
                    .font(.system(size: 22, weight: .medium))
                    .frame(width: 36, height: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(output.name)
                        .font(.system(size: 16, weight: .semibold))
                        .lineLimit(1)
                    Text(output.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Text(store.isAuthorized ? "已授权" : "未授权")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(store.isAuthorized ? .green : .orange)
            }
            Text("健康记录只能统计耳机音量和佩戴时长。单耳、左右耳、耳机仓电量、降噪和入耳检测都读不到。")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(16)
        .padding(.horizontal, 4)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .padding(.horizontal, 16)
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
                HeadphoneGlyph(kind: HeadphoneKind.match(device.name))
                    .frame(width: 86, height: 64)
                    .foregroundStyle(.white.opacity(0.9))
            }
            .frame(height: 92)

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

            VStack(alignment: .leading, spacing: 3) {
                statLine("佩戴次数", "\(device.sessionCount) 次")
                statLine("平均每次", durationText(device.averageSession))
                statLine("最长一次", durationText(device.longestSession))
                statLine("平均音量", volumeText(device.averageDecibels))
            }

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

    private func statLine(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer(minLength: 8)
            Text(value)
                .monospacedDigit()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func volumeText(_ decibels: Double?) -> String {
        guard let decibels, decibels.isFinite else { return "—" }
        return "\(Int(decibels.rounded())) dB"
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

/// 按健康记录里的型号名匹配轮廓。这是自己画的示意图，不是官网产品图。
enum HeadphoneKind {
    case max
    case pro
    case buds
    case generic

    static func match(_ name: String) -> HeadphoneKind {
        let lower = name.lowercased()
        if lower.contains("max") { return .max }
        if lower.contains("pro") { return .pro }
        if lower.contains("airpods") || lower.contains("buds") || lower.contains("freebuds") {
            return .buds
        }
        return .generic
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
            case .generic:
                drawGeneric(&context, size, stroke)
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
            let cup = CGRect(x: size.width * x, y: size.height * 0.42, width: size.width * 0.18, height: size.height * 0.48)
            context.stroke(Path(roundedRect: cup, cornerRadius: size.width * 0.08), with: .foreground, style: stroke)
        }
    }

    private func drawBuds(_ context: inout GraphicsContext, _ size: CGSize, _ stroke: StrokeStyle, stem: CGFloat) {
        for side in [0.08, 0.54] {
            let bud = CGRect(x: size.width * side, y: size.height * 0.08, width: size.width * 0.34, height: size.height * 0.42)
            context.stroke(Path(ellipseIn: bud), with: .foreground, style: stroke)
            var stick = Path()
            stick.move(to: CGPoint(x: size.width * (side + 0.17), y: size.height * 0.46))
            stick.addLine(to: CGPoint(x: size.width * (side + 0.17), y: size.height * (0.46 + stem * 0.5)))
            context.stroke(stick, with: .foreground, style: stroke)
        }
    }

    private func drawGeneric(_ context: inout GraphicsContext, _ size: CGSize, _ stroke: StrokeStyle) {
        var band = Path()
        band.move(to: CGPoint(x: size.width * 0.22, y: size.height * 0.48))
        band.addQuadCurve(to: CGPoint(x: size.width * 0.78, y: size.height * 0.48),
                          control: CGPoint(x: size.width * 0.5, y: 0))
        context.stroke(band, with: .foreground, style: stroke)
        for x in [0.10, 0.68] {
            let cup = CGRect(x: size.width * x, y: size.height * 0.36, width: size.width * 0.22, height: size.height * 0.5)
            context.stroke(Path(ellipseIn: cup), with: .foreground, style: stroke)
        }
    }
}
#endif
