#if os(iOS)
import SwiftUI
import UIKit

/// Douyin QR sign-in for Qishui. Also serves as the account panel once logged in.
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
    @State private var key: String?
    @State private var pollTask: Task<Void, Never>?
    @State private var didStart = false

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
            .padding(.vertical, 12)
            .navigationTitle("汽水音乐")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
            .onAppear {
                guard !session.isLoggedIn, !didStart else { return }
                didStart = true
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

    // MARK: - Logged in

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
                Text(session.isVIP ? "会员 · 整曲可用" : "非会员 · 部分歌曲只有试听")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Text("登录只用于读取汽水账号的曲库与播放权限。凭据保存在本机钥匙串，不上传服务器。车机接口最高提供 standard / high 音质，无损档位是加密的，本站不会解密。")
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
    }

    // MARK: - Logged out

    private var loginBody: some View {
        VStack(spacing: 18) {
            Text("使用抖音 App 扫码登录")
                .font(.title3.weight(.semibold))
                .padding(.top, 16)

            Text("未登录也能搜索和播放免费曲目；版权曲目只提供 30 秒试听，会员账号登录后才会返回整曲。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 24)

            qrCard
            statusView

            if case .expired = phase {
                Button("重新获取二维码") { startLogin() }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
            }
            if case .failed = phase {
                Button("重新获取二维码") { startLogin() }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
            }

            Spacer()
        }
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
            } else if case .failed = phase {
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
    }

    @ViewBuilder
    private var statusView: some View {
        switch phase {
        case .loading:
            Text("正在获取二维码…")
                .font(.footnote).foregroundStyle(.secondary)
        case .waiting:
            Text("打开抖音 App，扫码后确认授权")
                .font(.footnote).foregroundStyle(.secondary)
        case .scanned:
            Text("已扫码，请在抖音中确认")
                .font(.footnote).foregroundStyle(.secondary)
        case .expired:
            Text("二维码已失效，请重新获取")
                .font(.footnote).foregroundStyle(.secondary)
        case .failed(let message):
            Text(message)
                .font(.footnote)
                .foregroundStyle(.red)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
    }

    // MARK: - Flow

    @MainActor
    private func startLogin() {
        pollTask?.cancel()
        phase = .loading
        qrImage = nil
        key = nil
        Task {
            do {
                let newKey = try await QishuiAuthService.shared.start()
                key = newKey
                qrImage = Self.decodeImage(QishuiAuthService.shared.image(for: newKey))
                phase = .waiting
                startPolling(newKey)
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    @MainActor
    private func startPolling(_ key: String) {
        pollTask?.cancel()
        pollTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_800_000_000)
                if Task.isCancelled { return }
                do {
                    let state = try await QishuiAuthService.shared.check(key)
                    switch state {
                    case .waiting:
                        phase = .waiting
                    case .scanned:
                        phase = .scanned
                    case .confirmed:
                        return
                    case .expired:
                        phase = .expired
                        return
                    case .failed(let message):
                        phase = .failed(message)
                        return
                    }
                } catch {
                    phase = .failed(error.localizedDescription)
                    return
                }
            }
        }
    }

    private static func decodeImage(_ dataURL: String?) -> UIImage? {
        guard let dataURL else { return nil }
        let base64 = dataURL.components(separatedBy: "base64,").last ?? dataURL
        guard let data = Data(base64Encoded: base64) else { return nil }
        return UIImage(data: data)
    }
}
#endif
