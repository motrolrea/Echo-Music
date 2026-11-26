import Foundation
import SwiftUI

#if os(iOS)

/// Coordinates the short iOS launch transition and the first online warm-up.
///
/// The launch screen is deliberately time-bounded. Network requests continue
/// in the background after the main UI appears, so a slow provider can never
/// turn launch into a blank screen or an infinite spinner.
@MainActor
public final class IOSStartupCoordinator: ObservableObject {
    public static let shared = IOSStartupCoordinator()

    enum Phase: Equatable {
        case idle
        case warming
        case ready
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var isOnline = false
    @Published public private(set) var message = "正在唤醒声场"

    private var didStart = false
    private var preloadTasks: [Task<Void, Never>] = []

    private init() {}

    public var isReady: Bool { phase == .ready }

    func start(
        player: PlayerService,
        account: AccountStore,
        settings: SettingsManager
    ) async {
        guard !didStart else { return }
        didStart = true
        phase = .warming
        message = "正在唤醒声场"

        let startedAt = Date()
        player.startRuntime()

        preloadTasks.append(Task { @MainActor [weak self] in
            guard let self else { return }
            let networkOnline = await Self.probeOnlineService()
            let serverOnline = await MoumusicServerStore.shared.start()
            self.isOnline = networkOnline || serverOnline
            if !self.isOnline {
                self.message = "离线就绪，稍后自动重试"
            }
        })

        preloadTasks.append(Task { @MainActor in
            await account.bootstrap()
        })

        preloadTasks.append(Task { @MainActor in
            await MusicSessionRefreshCoordinator.shared.refreshIfNeeded()
        })

        preloadTasks.append(Task { @MainActor in
            await HomeViewModel.shared.load(
                loggedIn: account.isLoggedIn,
                mode: settings.homeRecommendationMode,
                platform: settings.homeRecommendationPlatform,
                qishuiSessionRevision: 0
            )
        })

        preloadTasks.append(Task { @MainActor in
            _ = await LXUserAPIService.shared.checkSelectedSource()
        })

        preloadTasks.append(Task { @MainActor in
            _ = try? await NeteaseAPI.searchDefaultKeyword()
        })

        let minimumDuration: TimeInterval = 1.35
        let remaining = minimumDuration - Date().timeIntervalSince(startedAt)
        if remaining > 0 {
            try? await Task.sleep(for: .seconds(remaining))
        }

        withAnimation(.easeInOut(duration: 0.48)) { phase = .ready }
        message = isOnline ? "正在载入推荐" : "应用已就绪，在线内容稍后重试"
    }

    private static func probeOnlineService() async -> Bool {
        guard let url = URL(string: "https://music.163.com/favicon.ico") else {
            return false
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 2.5
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let response = response as? HTTPURLResponse else { return false }
            return (200..<500).contains(response.statusCode)
        } catch {
            return false
        }
    }
}

public struct IOSStartupSplashView: View {
    @ObservedObject var coordinator: IOSStartupCoordinator
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @State private var appeared = false
    @State private var pulse = false
    @State private var vinylSpin = false
    @State private var wavePhase: CGFloat = 0
    @State private var orbit = false
    @State private var sweep = false
    @State private var bar = false
    @State private var glow = false

    public init(coordinator: IOSStartupCoordinator) {
        self.coordinator = coordinator
    }

    public var body: some View {
        ZStack {
            background
                .ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()
                hero
                Spacer()
                credits
            }
        }
        .allowsHitTesting(true)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Echo Music 正在启动")
        .onAppear {
            appeared = true
            if reduceMotion { return }
            withAnimation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true)) {
                pulse = true
            }
            withAnimation(.linear(duration: 14).repeatForever(autoreverses: false)) {
                vinylSpin = true
            }
            withAnimation(.linear(duration: 2.4).repeatForever(autoreverses: false)) {
                wavePhase = 1
            }
            withAnimation(.linear(duration: 3.4).repeatForever(autoreverses: false)) {
                sweep = true
            }
            withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true)) {
                bar = true
            }
            withAnimation(.linear(duration: 20).repeatForever(autoreverses: false)) {
                orbit = true
            }
            withAnimation(.linear(duration: 26).repeatForever(autoreverses: false)) {
                glow = true
            }
        }
    }

    private var background: some View {
        ZStack {
            LinearGradient(
                colors: colorScheme == .dark
                    ? [Color(red: 0.05, green: 0.05, blue: 0.08), Color(red: 0.11, green: 0.07, blue: 0.09)]
                    : [Color(red: 0.98, green: 0.96, blue: 0.94), Color(red: 0.94, green: 0.90, blue: 0.88)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            RadialGradient(
                colors: [Theme.accent.opacity(colorScheme == .dark ? 0.28 : 0.16), .clear],
                center: .center,
                startRadius: 20,
                endRadius: 340
            )

            // 缓慢旋转的柔光，让纯色背景多一点层次。
            Circle()
                .fill(
                    AngularGradient(
                        colors: [
                            Theme.accent.opacity(0.0),
                            Theme.accent.opacity(colorScheme == .dark ? 0.30 : 0.20),
                            Color.clear,
                            Theme.accent.opacity(colorScheme == .dark ? 0.16 : 0.12),
                            Color.clear,
                        ],
                        center: .center
                    )
                )
                .frame(width: 620, height: 620)
                .blur(radius: 100)
                .rotationEffect(.degrees(glow ? 360 : 0))
                .allowsHitTesting(false)
        }
    }

    private var hero: some View {
        VStack(spacing: 26) {
            ZStack {
                ForEach(0..<3, id: \.self) { index in
                    Circle()
                        .stroke(Theme.accent.opacity(pulse ? 0.08 : 0.28), lineWidth: 1.2)
                        .frame(width: 128 + CGFloat(index) * 42, height: 128 + CGFloat(index) * 42)
                        .scaleEffect(pulse ? 1.16 : 0.92)
                        .opacity(pulse ? 0.12 : 0.7)
                        .animation(
                            reduceMotion
                                ? nil
                                : .easeOut(duration: 1.8)
                                    .repeatForever(autoreverses: false)
                                    .delay(Double(index) * 0.22),
                            value: pulse
                        )
                }

                // 缓慢环绕的三个光点。
                ZStack {
                    ForEach(0..<3, id: \.self) { index in
                        Circle()
                            .fill(Theme.accent.opacity(colorScheme == .dark ? 0.85 : 0.6))
                            .frame(width: 5, height: 5)
                            .shadow(color: Theme.accent.opacity(0.6), radius: 4)
                            .offset(y: -88)
                            .rotationEffect(.degrees(Double(index) * 120))
                    }
                }
                .rotationEffect(.degrees(orbit ? 360 : 0))
                .opacity(reduceMotion ? 0 : 1)

                Circle()
                    .strokeBorder(.white.opacity(0.14), lineWidth: 7)
                    .frame(width: 124, height: 124)
                    .rotationEffect(.degrees(vinylSpin ? 360 : 0))

                BrandIconView(name: colorScheme == .dark ? "BrandAppIconDark" : "BrandAppIcon")
                    .frame(width: 92, height: 92)
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .overlay {
                        // 斜向流光扫过图标。
                        GeometryReader { proxy in
                            Rectangle()
                                .fill(
                                    LinearGradient(
                                        colors: [.clear, .white.opacity(0.5), .clear],
                                        startPoint: .top,
                                        endPoint: .bottom
                                    )
                                )
                                .frame(width: 30, height: proxy.size.height * 2)
                                .rotationEffect(.degrees(18))
                                .offset(x: sweep ? proxy.size.width + 46 : -70)
                                .blendMode(.plusLighter)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                        .allowsHitTesting(false)
                    }
                    .shadow(color: Theme.accent.opacity(0.35), radius: 18, y: 8)
                    .scaleEffect(appeared ? 1 : 0.86)
            }
            .frame(height: 228)

            VStack(spacing: 12) {
                Text("Echo Music")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .tracking(1.2)
                    .foregroundStyle(
                        LinearGradient(
                            colors: colorScheme == .dark
                                ? [.white, Theme.accent]
                                : [Color(red: 0.15, green: 0.12, blue: 0.16), Theme.accent],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )

                Text(coordinator.message)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .animation(.easeInOut(duration: 0.25), value: coordinator.message)

                EchoWaveform(phase: wavePhase)
                    .frame(width: 148, height: 18)
                    .padding(.top, 2)

                // 不确定进度条：来回滑动，表示仍在准备内容。
                Capsule()
                    .fill(Color.primary.opacity(0.08))
                    .frame(width: 132, height: 3)
                    .overlay(alignment: .leading) {
                        Capsule()
                            .fill(Theme.accent)
                            .frame(width: 46, height: 3)
                            .offset(x: bar ? 86 : 0)
                    }
                    .clipShape(Capsule())
                    .padding(.top, 8)
                    .opacity(reduceMotion ? 0.5 : 1)
            }
            .padding(.horizontal, 32)
        }
    }

    private var credits: some View {
        VStack(spacing: 7) {
            Capsule()
                .fill(Color.primary.opacity(0.12))
                .frame(width: 34, height: 1)
                .padding(.bottom, 2)
            Text("基于 Beans Music 与 Moumusic 二次创作")
            Text("保留原项目核心能力，重新设计播放体验")
            Text("仅供学习交流使用")
        }
        .font(.caption2)
        .foregroundStyle(.tertiary)
        .multilineTextAlignment(.center)
        .padding(.horizontal, 28)
        .padding(.bottom, 30)
    }
}

private struct EchoWaveform: View {
    let phase: CGFloat

    var body: some View {
        GeometryReader { geo in
            let bars = 11
            HStack(alignment: .center, spacing: 4) {
                ForEach(0..<bars, id: \.self) { index in
                    Capsule()
                        .fill(Theme.accent.opacity(0.85))
                        .frame(width: 4, height: barHeight(index: index, max: geo.size.height))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func barHeight(index: Int, max height: CGFloat) -> CGFloat {
        let wave = sin((Double(index) / 3.2) + Double(phase) * .pi * 2)
        let normalized = 0.28 + 0.72 * abs(wave)
        return max(4, height * normalized)
    }
}

#endif
