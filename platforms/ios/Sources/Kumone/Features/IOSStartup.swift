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

/// 开屏配色：深海靛蓝底 + 青蓝极光 + 一点暖金，独立于 App 主题色。
enum StartupPalette {
    static let teal = Color(red: 0.36, green: 0.80, blue: 0.87)
    static let indigo = Color(red: 0.49, green: 0.56, blue: 0.96)
    static let amber = Color(red: 0.97, green: 0.85, blue: 0.66)
}

public struct IOSStartupSplashView: View {
    @ObservedObject var coordinator: IOSStartupCoordinator
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @State private var appeared = false
    @State private var discSpin = false
    @State private var wavePhase: CGFloat = 0
    @State private var sweep = false
    @State private var drift = false
    @State private var bar = false

    public init(coordinator: IOSStartupCoordinator) {
        self.coordinator = coordinator
    }

    public var body: some View {
        ZStack {
            backdrop
                .ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer(minLength: 0)
                hero
                Spacer(minLength: 0)
                credits
            }
        }
        .allowsHitTesting(true)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Echo Music 正在启动")
        .onAppear {
            appeared = true
            if reduceMotion { return }
            withAnimation(.linear(duration: 18).repeatForever(autoreverses: false)) {
                discSpin = true
            }
            withAnimation(.linear(duration: 2.6).repeatForever(autoreverses: false)) {
                wavePhase = 1
            }
            withAnimation(.linear(duration: 3.8).repeatForever(autoreverses: false)) {
                sweep = true
            }
            withAnimation(.easeInOut(duration: 9).repeatForever(autoreverses: true)) {
                drift = true
            }
            withAnimation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true)) {
                bar = true
            }
        }
    }

    private var backdrop: some View {
        ZStack {
            LinearGradient(
                colors: colorScheme == .dark
                    ? [
                        Color(red: 0.031, green: 0.043, blue: 0.074),
                        Color(red: 0.047, green: 0.058, blue: 0.098),
                        Color(red: 0.020, green: 0.026, blue: 0.043),
                    ]
                    : [
                        Color(red: 0.988, green: 0.990, blue: 0.996),
                        Color(red: 0.941, green: 0.951, blue: 0.972),
                        Color(red: 0.980, green: 0.982, blue: 0.989),
                    ],
                startPoint: .top,
                endPoint: .bottom
            )

            // 两团缓慢漂移的极光，取代纯色背景。
            ZStack {
                Ellipse()
                    .fill(StartupPalette.teal.opacity(colorScheme == .dark ? 0.26 : 0.14))
                    .frame(width: 400, height: 280)
                    .blur(radius: 110)
                    .offset(x: drift ? -96 : -30, y: drift ? -156 : -58)
                Ellipse()
                    .fill(StartupPalette.indigo.opacity(colorScheme == .dark ? 0.30 : 0.13))
                    .frame(width: 450, height: 320)
                    .blur(radius: 120)
                    .offset(x: drift ? 112 : 40, y: drift ? 196 : 118)
                Ellipse()
                    .fill(StartupPalette.amber.opacity(colorScheme == .dark ? 0.07 : 0.10))
                    .frame(width: 220, height: 160)
                    .blur(radius: 90)
                    .offset(x: drift ? 84 : 120, y: drift ? -230 : -280)
            }
            .rotationEffect(.degrees(drift ? 6 : -6))

            StartupDust(tint: colorScheme == .dark ? .white : Color(red: 0.22, green: 0.28, blue: 0.40))

            // 上下轻微压暗，让主体更聚光。
            LinearGradient(
                colors: colorScheme == .dark
                    ? [Color.black.opacity(0.28), .clear, Color.black.opacity(0.30)]
                    : [Color.white.opacity(0.42), .clear, Color.white.opacity(0.36)],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }

    private var hero: some View {
        VStack(spacing: 26) {
            emblem
                .frame(height: 300)

            VStack(spacing: 12) {
                Text("Echo Music")
                    .font(.system(size: 29, weight: .semibold, design: .rounded))
                    .tracking(2.2)
                    .foregroundStyle(
                        LinearGradient(
                            colors: colorScheme == .dark
                                ? [.white, Color(red: 0.70, green: 0.87, blue: 0.94)]
                                : [Color(red: 0.10, green: 0.13, blue: 0.20), Color(red: 0.30, green: 0.43, blue: 0.60)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )

                Text(coordinator.message)
                    .font(.footnote.weight(.medium))
                    .tracking(0.5)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .animation(.easeInOut(duration: 0.25), value: coordinator.message)

                EchoWaveform(phase: wavePhase)
                    .frame(width: 132, height: 16)
                    .padding(.top, 4)

                // 不确定进度：一条细光在轨道里来回滑动。
                Capsule()
                    .fill(Color.primary.opacity(colorScheme == .dark ? 0.10 : 0.07))
                    .frame(width: 140, height: 5)
                    .overlay(alignment: .leading) {
                        Capsule()
                            .fill(
                                LinearGradient(
                                    colors: [StartupPalette.teal, StartupPalette.indigo],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .frame(width: 48, height: 5)
                            .offset(x: bar ? 92 : 0)
                    }
                    .clipShape(Capsule())
                    .padding(.top, 26)
                    .opacity(reduceMotion ? 0.5 : 1)
            }
            .padding(.horizontal, 32)
        }
    }

    private var emblem: some View {
        ZStack {
            // 图标背后的大范围柔光，充当光环的底座。
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            StartupPalette.teal.opacity(colorScheme == .dark ? 0.20 : 0.13),
                            StartupPalette.indigo.opacity(colorScheme == .dark ? 0.10 : 0.07),
                            .clear,
                        ],
                        center: .center,
                        startRadius: 10,
                        endRadius: 190
                    )
                )
                .frame(width: 340, height: 340)
                .blur(radius: 18)

            // 向外扩散的同心光环，像声波一圈圈推开。
            if !reduceMotion {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
                    let now = timeline.date.timeIntervalSinceReferenceDate
                    ZStack {
                        ForEach(0..<3, id: \.self) { index in
                            let phase = (now / 3.2 + Double(index) / 3.0)
                                .truncatingRemainder(dividingBy: 1)
                            Circle()
                                .stroke(StartupPalette.indigo.opacity(0.32 * (1 - phase)), lineWidth: 0.9)
                                .frame(width: 190, height: 190)
                                .scaleEffect(0.82 + CGFloat(phase) * 0.68)
                        }
                    }
                }
                .frame(width: 300, height: 300)
            }

            Circle()
                .stroke(Color.primary.opacity(0.08), lineWidth: 0.8)
                .frame(width: 190, height: 190)

            // 唱片外圈：青蓝渐变细环，缓慢自转。
            Circle()
                .strokeBorder(
                    AngularGradient(
                        colors: [
                            StartupPalette.teal.opacity(0.0),
                            StartupPalette.teal.opacity(0.55),
                            StartupPalette.indigo.opacity(0.65),
                            StartupPalette.indigo.opacity(0.0),
                        ],
                        center: .center
                    ),
                    lineWidth: 1.6
                )
                .frame(width: 168, height: 168)
                .rotationEffect(.degrees(discSpin ? 360 : 0))

            Circle()
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 7)
                .frame(width: 150, height: 150)

            // 图标下方的柔和投影，替代原来的彩色光斑。
            Ellipse()
                .fill(StartupPalette.teal.opacity(colorScheme == .dark ? 0.18 : 0.12))
                .frame(width: 128, height: 24)
                .blur(radius: 24)
                .offset(y: 80)

            BrandIconView(name: colorScheme == .dark ? "BrandAppIconDark" : "BrandAppIcon")
                .frame(width: 92, height: 92)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .overlay {
                    // 斜向流光扫过图标。
                    GeometryReader { proxy in
                        Rectangle()
                            .fill(
                                LinearGradient(
                                    colors: [.clear, .white.opacity(0.42), .clear],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                            .frame(width: 28, height: proxy.size.height * 2)
                            .rotationEffect(.degrees(18))
                            .offset(x: sweep ? proxy.size.width + 44 : -66)
                            .blendMode(.plusLighter)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .allowsHitTesting(false)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.8)
                }
                .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.45 : 0.18), radius: 18, y: 10)
                .scaleEffect(appeared ? 1 : 0.88)
                .opacity(appeared ? 1 : 0)
                .animation(.easeOut(duration: 0.55), value: appeared)
        }
    }

    private var credits: some View {
        VStack(spacing: 7) {
            Capsule()
                .fill(Color.primary.opacity(0.10))
                .frame(width: 30, height: 1)
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

/// 缓慢呼吸的细小星尘，让大面积留白不显得空。
private struct StartupDust: View {
    let tint: Color
    @State private var lit = false

    var body: some View {
        GeometryReader { proxy in
            ForEach(0..<22, id: \.self) { index in
                let x = CGFloat(pseudo(index * 37 + 5)) * proxy.size.width
                let y = CGFloat(pseudo(index * 71 + 13)) * proxy.size.height
                Circle()
                    .fill(tint.opacity(0.55))
                    .frame(width: index % 6 == 0 ? 2.2 : 1.3)
                    .position(x: x, y: y)
                    .opacity(lit ? 0.55 : 0.10)
                    .animation(
                        .easeInOut(duration: 2.2 + Double(index % 7) * 0.32)
                            .repeatForever(autoreverses: true)
                            .delay(Double(index) * 0.07),
                        value: lit
                    )
            }
        }
        .allowsHitTesting(false)
        .onAppear { lit = true }
    }

    private func pseudo(_ value: Int) -> Double {
        let raw = sin(Double(value) * 12.9898) * 43758.5453
        return raw - floor(raw)
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
                        .fill(
                            LinearGradient(
                                colors: [StartupPalette.teal.opacity(0.85), StartupPalette.indigo.opacity(0.85)],
                                startPoint: .bottom,
                                endPoint: .top
                            )
                        )
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
