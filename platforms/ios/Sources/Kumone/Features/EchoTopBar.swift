import SwiftUI

struct EchoAvatarButton: View {
    /// Stays under the 44pt bar height, so iOS keeps the proposed square.
    var size: CGFloat = 42
    @Environment(\.openProfile) private var openProfile
    @EnvironmentObject private var account: AccountStore
#if os(iOS)
    @ObservedObject private var appearance = ProfileAppearanceStore.shared
#endif

    var body: some View {
        Button(action: openProfile) {
            ZStack {
                Circle().fill(.ultraThinMaterial)
                avatar
                    .frame(width: size, height: size)
                    .clipShape(Circle())
            }
            .frame(width: size, height: size)
            .clipShape(Circle())
            .overlay {
                Circle().strokeBorder(
                    LinearGradient(
                        colors: [.white.opacity(0.75), .white.opacity(0.18)],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 1.6
                )
            }
        }
        .buttonStyle(.plain)
        .frame(width: size, height: size)
        .fixedSize()
        .accessibilityLabel("个人信息")
    }

    @ViewBuilder
    private var avatar: some View {
#if os(iOS)
        if let custom = appearance.avatar {
            Image(uiImage: custom).resizable().scaledToFill()
        } else {
            remoteAvatar
        }
#else
        remoteAvatar
#endif
    }

    @ViewBuilder
    private var remoteAvatar: some View {
        if let profile = account.profile {
            CachedAsyncImage(url: profile.avatarUrl?.resizedImageURL(160)) {
                Image(systemName: "person.crop.circle.fill")
                    .resizable().scaledToFit().foregroundStyle(.secondary)
            }
        } else {
            Image(systemName: "person.crop.circle.fill")
                .resizable().scaledToFit().foregroundStyle(.secondary)
        }
    }
}

struct EchoPlaylistActions: View {
    var onImport: () -> Void
    var onCreate: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onImport) {
                Image(systemName: "square.and.arrow.down")
                    .frame(width: 34, height: 32)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("导入歌单")
            Rectangle()
                .fill(.primary.opacity(0.16))
                .frame(width: 1, height: 14)
            Button(action: onCreate) {
                Image(systemName: "plus")
                    .frame(width: 34, height: 32)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("新建歌单")
        }
        .font(.system(size: 15, weight: .semibold))
        .foregroundStyle(.primary)
        .buttonStyle(.plain)
        .padding(.horizontal, 2)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay { Capsule().strokeBorder(.white.opacity(0.32), lineWidth: 0.8) }
    }
}

#if os(iOS)
extension ToolbarContent {
    /// iOS 26 draws a shared capsule behind toolbar items and stretches circles.
    @ToolbarContentBuilder
    func echoCircleItem() -> some ToolbarContent {
        if #available(iOS 26.0, *) {
            self.sharedBackgroundVisibility(.hidden)
        } else {
            self
        }
    }
}
#endif
