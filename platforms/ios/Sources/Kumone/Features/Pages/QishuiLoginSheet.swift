#if os(iOS)
import CoreImage.CIFilterBuiltins
import SwiftUI
import UIKit

/// 汽水登录。官网首页只有下载按钮，这里改成汽水 App 扫码。
struct QishuiLoginSheet: View {
    private enum Phase: Equatable {
        case loading
        case waiting
        case scanned
        case expired
        case failed(String)
    }

    @ObservedObject private var session = QishuiSessionStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var phase: Phase = .loading
    @State private var qrImage: UIImage?
    @State private var pollTask: Task<Void, Never>?
    @State private var didStartLogin = false
    @State private var didAutoRefreshExpiredCode = false
    @State private var loginGeneration = UUID()

    var body: some View {
        NavigationStack {
            Group {
                if session.isLoggedIn {
                    accountBody
                } else {
                    loginBody
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .navigationTitle("汽水音乐")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(session.isLoggedIn ? "关闭" : "取消") {
                        pollTask?.cancel()
                        dismiss()
                    }
                }
            }
            .onAppear {
                guard !session.isLoggedIn, !didStartLogin else { return }
                didStartLogin = true
                startLogin()
            }
            .onDisappear { pollTask?.cancel() }
            .onChange(of: session.isLoggedIn) { loggedIn in
                guard loggedIn else { return }
                pollTask?.cancel()
                pollTask = nil
            }
        }
    }

    private var accountBody: some View {
        VStack(spacing: 18) {
            Group {
                if let avatar = session.avatarURL, let url = URL(string: avatar) {
                    AsyncImage(url: url) { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        Image(systemName: "drop.fill")
                            .font(.system(size: 30, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                    .frame(width: 84, height: 84)
                    .clipShape(Circle())
                } else {
                    Image(systemName: "drop.fill")
                        .font(.system(size: 34, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 84, height: 84)
                        .background(Color.pink, in: Circle())
                }
            }
            .padding(.top, 24)

            VStack(spacing: 6) {
                Text(session.profileName ?? "汽水音乐用户")
                    .font(.title3.weight(.semibold))
                Text(session.isVIP ? "会员 · 整曲可用" : "已登录 · 可读取收藏和歌单")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Text("登录只用于读取汽水账号的歌单、收藏和播放权限。凭据保存在本机钥匙串，不上传服务器。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 28)

            Button(role: .destructive) {
                session.signOut()
                dismiss()
            } label: {
                Text("退出汽水音乐")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .padding(.horizontal, 28)

            Spacer()
        }
        .padding(.vertical, 12)
    }

    private var loginBody: some View {
        VStack(spacing: 18) {
            Text("使用汽水音乐 App 扫码登录")
                .font(.title3.weight(.semibold))
                .padding(.top, 16)

            Text("打开手机上的汽水音乐，扫描下面的二维码并确认。收藏、自建歌单和「我喜欢」都会保留，登录后可以播放完整歌曲。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 24)

            qrCard
            statusView

            if phase == .expired || isFailed {
                Button("重新获取二维码") { startLogin() }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
            }
        }
        .padding(.vertical, 12)
    }

    private var qrCard: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(.white)
                .frame(width: 272, height: 272)
                .shadow(color: .black.opacity(0.12), radius: 18, y: 8)
            if let qrImage {
                Image(uiImage: qrImage)
                    .resizable()
                    .interpolation(.none)
                    .scaledToFit()
                    .frame(width: 232, height: 232)
                    .opacity(phase == .expired ? 0.25 : 1)
            } else if isFailed {
                VStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 30))
                        .foregroundStyle(Theme.accent)
                    Text("二维码暂时不可用")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            } else {
                ProgressView()
            }
            if phase == .expired || phase == .scanned {
                VStack(spacing: 8) {
                    Image(systemName: phase == .expired ? "arrow.clockwise.circle.fill" : "checkmark.circle.fill")
                        .font(.system(size: 34))
                        .foregroundStyle(phase == .expired ? Theme.accent : .green)
                    Text(phase == .expired ? "二维码已失效" : "已扫码，请在手机上确认")
                        .font(.subheadline.weight(.semibold))
                }
                .padding(16)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("汽水音乐扫码登录二维码")
    }

    private var isFailed: Bool {
        if case .failed = phase { return true }
        return false
    }

    @ViewBuilder
    private var statusView: some View {
        switch phase {
        case .loading:
            Label("正在获取二维码…", systemImage: "arrow.triangle.2.circlepath")
        case .waiting:
            Label("打开汽水音乐 App 扫一扫", systemImage: "qrcode.viewfinder")
        case .scanned:
            Label("已扫码，等待手机确认…", systemImage: "iphone")
        case .expired:
            Label("二维码已过期", systemImage: "clock.badge.exclamationmark")
                .foregroundStyle(Theme.accent)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.accent)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
    }

    private func startLogin(automaticRefresh: Bool = false) {
        guard !session.isLoggedIn else { return }
        pollTask?.cancel()
        let generation = UUID()
        loginGeneration = generation
        phase = .loading
        qrImage = nil
        if !automaticRefresh { didAutoRefreshExpiredCode = false }
        pollTask = Task { @MainActor in
            defer {
                if generation == loginGeneration { pollTask = nil }
            }
            do {
                let login = QishuiQRLogin()
                let code = try await login.fetch()
                guard generation == loginGeneration else { return }
                guard let image = Self.makeQRImage(from: code.scanURL.absoluteString) else {
                    throw QishuiError(.invalidResponse, "登录二维码无法显示，请重试")
                }
                qrImage = image
                phase = .waiting

                var errors = 0
                while !Task.isCancelled {
                    guard generation == loginGeneration else { return }
                    try await Task.sleep(for: .seconds(2))
                    do {
                        let status = try await login.poll(token: code.token, expiresAt: code.expiresAt)
                        guard generation == loginGeneration else { return }
                        switch status {
                        case .waiting:
                            phase = .waiting
                        case .scanned, .processing:
                            phase = .scanned
                        case .expired:
                            pollTask = nil
                            if !didAutoRefreshExpiredCode {
                                didAutoRefreshExpiredCode = true
                                phase = .loading
                                try? await Task.sleep(for: .milliseconds(350))
                                guard !Task.isCancelled,
                                      generation == loginGeneration,
                                      !session.isLoggedIn else { return }
                                startLogin(automaticRefresh: true)
                            } else {
                                phase = .expired
                            }
                            return
                        case .confirmed(let cookie):
                            do {
                                _ = try await QishuiAuthService.shared.signIn(cookie: cookie)
                                guard generation == loginGeneration else { return }
                                ToastCenter.shared.show("汽水音乐登录成功")
                                pollTask = nil
                                dismiss()
                                return
                            } catch {
                                pollTask = nil
                                phase = .failed(error.localizedDescription)
                                return
                            }
                        }
                        errors = 0
                    } catch {
                        errors += 1
                        if errors >= 6 { throw error }
                    }
                }
            } catch {
                if !Task.isCancelled, generation == loginGeneration {
                    pollTask = nil
                    phase = .failed(error.localizedDescription)
                }
            }
        }
    }

    private static func makeQRImage(from value: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(value.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 12, y: 12))
        guard let cgImage = CIContext().createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}
#endif
