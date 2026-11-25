#if os(iOS)
import PhotosUI
import SwiftUI

/// Beans-style 闂傚倸鍊烽懗鍫曞磻閵娾晛纾块柤纰卞墮閸ㄦ繄鈧箍鍎遍ˇ顖炲垂閸屾稓绡€濠电姴鍊绘晶娑㈡煕鎼达紕效闁哄本鐩鏉懳熼崫鍕庛劑姊?surface.  It is intentionally a real navigation hub,
/// not a decorative replacement for Settings: every card opens the existing
/// Moumusic feature and keeps the account/source separation intact.
struct MyProfileView: View {
    @EnvironmentObject private var account: AccountStore
    @EnvironmentObject private var settings: SettingsManager
    @EnvironmentObject private var player: PlayerService
    @EnvironmentObject private var qqMusic: QQMusicSessionStore
    @EnvironmentObject private var kugou: KugouSessionStore
    @EnvironmentObject private var bilibili: BilibiliSessionStore
    @ObservedObject private var qishui = QishuiSessionStore.shared
    @ObservedObject private var migu = MiguSessionStore.shared
    @Environment(\.openLogin) private var openLogin
    @StateObject private var syncStore = ListeningSyncStore.shared
    @StateObject private var moumusicServer = MoumusicServerStore.shared
    @State private var showDownloads = false
    @State private var showMoumusicAdminLogin = false
    @State private var showMoumusicAdminUsers = false
    @State private var showQQMusicLogin = false
    @State private var showKugouLogin = false
    @State private var showQishuiLogin = false
    @State private var showMiguLogin = false
    @State private var showBilibiliLogin = false
    @State private var showMoumusicProfileEditor = false
    @ObservedObject private var deviceReporter = DeviceReporter.shared
    @State private var showDeviceCode = false
    @State private var showCustomize = false
    @State private var showAggregate = false
    @AppStorage("echo.profile.aggregateOnHome") private var aggregateOnHome = false
    @AppStorage("moumusic.home.bilibiliActive") private var bilibiliActive = false
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var appearance = ProfileAppearanceStore.shared
    @ObservedObject private var stats = ListeningStatsStore.shared
    @State private var signedInTarget: SignedInTarget?
    @State private var showAccountPlaylists = false
    private enum SignedInTarget: String, Identifiable { case qq, kugou, bilibili; var id: String { rawValue } }


    var body: some View {
        Group {
            if bilibiliActive, settings.bilibiliMode != .disabled {
                // 哔哩哔哩平台的「我的」直接就是账号个人信息页。
                if bilibili.isLoggedIn {
                    BilibiliContentView(locked: .account)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            bilibiliProfile
                            PlayerClearanceSpacer()
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 10)
                    }
                    .scrollIndicators(.hidden)
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        if aggregateOnHome {
                            aggregateSections
                        } else {
                            platformHome
                        }
                        PlayerClearanceSpacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
                    .modifier(BeansScrollCollapseTracker())
                }
                .coordinateSpace(name: BeansScrollCollapse.coordinateSpace)
                .scrollIndicators(.hidden)
            }
        }
        .task {
            _ = await moumusicServer.start()
            await DeviceReporter.shared.reportHeartbeat()
        }
        .navigationTitle("我的")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Menu {
                    Section("切换平台") {
                        ForEach(LXCatalogPlatform.switcherCases) { platform in
                            Button {
                                bilibiliActive = false
                                settings.homeRecommendationMode = platform == .wy ? .netease : .lx
                                settings.homeRecommendationPlatform = platform
                            } label: {
                                HStack(spacing: 8) {
                                    PlatformGlyph(platform: platform, contentMode: .fill)
                                        .frame(width: 28, height: 28)
                                        .clipShape(Circle())
                                    Text(platform.displayName)
                                }
                            }
                        }
                        if settings.bilibiliMode != .disabled {
                            Button {
                                bilibiliActive = true
                            } label: {
                                HStack(spacing: 8) {
                                    BrandIconView(name: "BrandBilibili", contentMode: .fill)
                                        .frame(width: 28, height: 28)
                                        .clipShape(Circle())
                                    Text("哔哩哔哩")
                                }
                            }
                        }
                    }
                } label: {
                    profilePlatformBadge
                }
                .accessibilityLabel("切换平台")
            }
            .echoCircleItem()
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    if aggregateOnHome {
                        aggregateOnHome = false
                        ToastCenter.shared.show("我的页面显示当前平台")
                    } else {
                        showAggregate = true
                    }
                } label: {
                    Image(systemName: aggregateOnHome ? "person.crop.rectangle.fill" : "person.crop.rectangle")
                        .font(.system(size: 16, weight: .semibold))
                }
                .accessibilityLabel(aggregateOnHome ? "改回当前平台" : "汇总")
            }
            ToolbarItem(placement: .topBarTrailing) {
                ThemeRevealButton()
                    .font(.system(size: 16, weight: .semibold))
            }
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    SettingsView()
                } label: {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 16, weight: .semibold))
                }
                .accessibilityLabel("设置")
            }
        }
        .sheet(isPresented: $showDownloads) {
            NavigationStack {
                DownloadsView()
                    .environmentObject(player)
            }
            .presentationDetents([.large])
        }
        .sheet(isPresented: $showMoumusicAdminLogin) {
            MoumusicAdminLoginView()
                .environmentObject(moumusicServer)
        }
        .sheet(isPresented: $showMoumusicAdminUsers) {
            MoumusicAdminUsersView()
                .environmentObject(moumusicServer)
        }
        .sheet(isPresented: $showQQMusicLogin) {
            QQMusicLoginSheet()
                .environmentObject(qqMusic)
        }
        .sheet(isPresented: $showKugouLogin) {
            KugouLoginSheet()
                .environmentObject(kugou)
        }
        .sheet(isPresented: $showQishuiLogin) {
            QishuiLoginSheet()
        }
        .sheet(isPresented: $showMiguLogin) {
            ProviderWebLoginSheet(provider: .migu) { cookie in
                try await MainActor.run {
                    try MiguSessionStore.shared.signIn(cookie: cookie)
                }
            }
        }
        .sheet(isPresented: $showBilibiliLogin) {
            BilibiliLoginSheet()
                .environmentObject(bilibili)
        }
        .sheet(isPresented: $showCustomize) {
            ProfileCustomizeSheet()
        }
        .sheet(isPresented: $showAggregate) {
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        Toggle("在我的页面显示汇总", isOn: $aggregateOnHome)
                            .padding(.horizontal, 4)
                        aggregateSections
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
                    .padding(.bottom, 24)
                }
                .navigationTitle("汇总")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("完成") { showAggregate = false }
                    }
                }
            }
        }
        .sheet(isPresented: $showDeviceCode) {
            DeviceCodeSheet()
        }
        .navigationDestination(isPresented: $showAccountPlaylists) {
            AccountPlaylistsView()
        }
        .sheet(item: $signedInTarget) { target in
            switch target {
            case .qq:
                PlatformAccountPage(platform: .tx).environmentObject(qqMusic).environmentObject(kugou).environmentObject(player)
            case .kugou:
                PlatformAccountPage(platform: .kg).environmentObject(qqMusic).environmentObject(kugou).environmentObject(player)
            case .bilibili:
                BilibiliAccountPage().environmentObject(bilibili).environmentObject(player)
            }
        }
        .sheet(isPresented: $showMoumusicProfileEditor) {
            MoumusicProfileEditorView()
                .environmentObject(moumusicServer)
        }
    }

    /// One compact card: who you are, account state and listening totals. The
    /// large profile card lives behind the "名片" button.
    private func signedInTitle(_ target: SignedInTarget) -> String {
        switch target {
        case .qq: return "QQ 音乐"
        case .kugou: return "酷狗音乐"
        case .bilibili: return "哔哩哔哩"
        }
    }

    /// The ID capsule. A granted exclusive ID gets the crown and the gold style
    /// chosen on the server (black-purple-gold or classic gold).
    private var idBadge: some View {
        let exclusive = !deviceReporter.exclusiveID.isEmpty
        let id = String(deviceReporter.displayID.prefix(24))
        let classic = deviceReporter.badgeStyle == .classicGold
        let gold = Color(red: 0.96, green: 0.76, blue: 0.30)
        let textColor: Color = exclusive ? (classic ? Color(red: 0.24, green: 0.16, blue: 0.0) : gold) : .secondary
        return Button {
            UIPasteboard.general.string = id
            ToastCenter.shared.show("用户 ID 已复制")
        } label: {
            HStack(spacing: 5) {
                if exclusive {
                    Image(systemName: "crown.fill").font(.system(size: 12, weight: .bold))
                } else {
                    Image(systemName: "number")
                        .font(.system(size: 7, weight: .heavy))
                        .foregroundStyle(.white)
                        .frame(width: 14, height: 14)
                        .background(Color.secondary.opacity(0.8), in: Circle())
                }
                Text(exclusive ? "专属 ID · \(id)" : "ID · \(id)")
                Image(systemName: "doc.on.doc").font(.system(size: 10, weight: .semibold))
            }
            .font(.system(size: exclusive ? 12 : 12, weight: exclusive ? .heavy : .medium, design: .rounded))
            .foregroundStyle(textColor)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background {
                if !exclusive {
                    Capsule().fill(BackgroundImageStore.shared.appWallpaperActive
                                   ? AnyShapeStyle(Color.clear) : AnyShapeStyle(.thinMaterial))
                        .overlay(Capsule().strokeBorder(.white.opacity(0.35), lineWidth: 0.8))
                }
                if exclusive {
                    Capsule().fill(
                        classic
                            ? LinearGradient(colors: [Color(red: 0.98, green: 0.84, blue: 0.45), Color(red: 0.80, green: 0.58, blue: 0.16)],
                                             startPoint: .leading, endPoint: .trailing)
                            : LinearGradient(colors: [Color(red: 0.07, green: 0.05, blue: 0.16), Color(red: 0.24, green: 0.12, blue: 0.43)],
                                             startPoint: .leading, endPoint: .trailing))
                }
            }
            .overlay {
                if exclusive {
                    Capsule().strokeBorder(
                        LinearGradient(colors: [gold, .white.opacity(0.9), gold], startPoint: .topLeading, endPoint: .bottomTrailing),
                        lineWidth: 1.2)
                }
            }
            .overlay {
                if exclusive { GoldShimmer().clipShape(Capsule()).allowsHitTesting(false) }
            }
            .shadow(color: exclusive ? gold.opacity(0.55) : .clear, radius: exclusive ? 8 : 0)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(exclusive ? "专属 ID \(id)，点击复制" : "用户 ID \(id)，点击复制")
    }
    private var compactIdentity: some View {
        let hasBackground = appearance.background != nil
        return MouGlassCard(cornerRadius: 24, padding: 14) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Group {
                        if let custom = appearance.avatar {
                            Image(uiImage: custom).resizable().scaledToFill()
                        } else if let profile = account.profile {
                            CachedAsyncImage(url: profile.avatarUrl?.resizedImageURL(160)) {
                                Image(systemName: "person.crop.circle.fill")
                                    .resizable().scaledToFit().foregroundStyle(.secondary)
                            }
                        } else {
                            Image(systemName: "person.crop.circle.fill")
                                .resizable().scaledToFit().foregroundStyle(.secondary)
                        }
                    }
                    .frame(width: 54, height: 54)
                    .clipShape(Circle())
                    .padding(2)
                    .background { Circle().fill(.ultraThinMaterial) }
                    .overlay {
                        Circle().strokeBorder(
                            LinearGradient(
                                colors: [.white.opacity(0.78), .white.opacity(0.18)],
                                startPoint: .top,
                                endPoint: .bottom
                            ),
                            lineWidth: 1.2
                        )
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        Text(appearance.nickname.trimmingCharacters(in: .whitespaces).isEmpty ? (account.profile?.nickname ?? "Echo Music 用户") : appearance.nickname)
                            .font(.headline)
                            .lineLimit(1)
                        HStack(spacing: 8) {
                            idBadge
                            Button {
                                showDeviceCode = true
                            } label: {
                                Text("设备码")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    Spacer(minLength: 8)
                    Button {
                        showCustomize = true
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                            .font(.system(size: 16, weight: .semibold))
                            .frame(width: 40, height: 40)
                            .mouMaterialBackground(.thinMaterial, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("自定义头像和背景")
                }
                HStack(spacing: 10) {
                    metric(title: "本机听歌时长", value: stats.formattedDuration)
                    metric(title: "播放歌曲", value: "\(stats.totalPlayCount) 首")
                    metric(title: "连续听歌", value: "\(stats.streakDays) 天")
                }
            }
        }
        .background {
            if let image = appearance.background {
                // Size the layer to the card first, then fill+clip inside it,
                // otherwise a large photo overflows the screen.
                Color.clear
                    .overlay {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                    }
                    .overlay(Color.black.opacity(0.38))
                    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                    .allowsHitTesting(false)
            }
        }
        .environment(\.colorScheme, hasBackground ? .dark : colorScheme)
    }
    private var accountCard: some View {
        MouGlassCard(cornerRadius: 28) {
            HStack(spacing: 14) {
                if let profile = account.profile {
                    CachedAsyncImage(url: profile.avatarUrl?.resizedImageURL(192)) {
                        Image(systemName: "person.crop.circle.fill")
                            .font(.system(size: 52))
                            .foregroundStyle(.secondary)
                    }
                    .frame(width: 68, height: 68)
                    .clipShape(Circle())
                } else {
                    Image(systemName: "person.crop.circle.fill")
                        .font(.system(size: 50))
                        .foregroundStyle(.secondary)
                        .frame(width: 68, height: 68)
                }

                VStack(alignment: .leading, spacing: 5) {
                    Text(account.profile?.nickname ?? "未登录")
                        .font(.title3.weight(.bold))
                        .lineLimit(1)
                    Text(account.isLoggedIn ? "账号资料与歌单已同步" : "登录后同步歌单与播放记录")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 8)
                NavigationLink(value: Destination.accountSync) {
                    Image(systemName: account.isLoggedIn ? "checkmark.circle.fill" : "person.badge.plus")
                        .font(.title2)
                        .foregroundStyle(account.isLoggedIn ? .green : Theme.accent)
                }
                .accessibilityLabel(account.isLoggedIn ? "查看账号同步" : "登录")
            }
        }
    }

    private var moumusicIdentityCardLegacy: some View {
#if false
        MouGlassCard(cornerRadius: 28) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 14) {
                    if let value = moumusicServer.profile?.avatarURL, let url = URL(string: value) {
                        AsyncImage(url: url) { phase in
                            if case .success(let image) = phase {
                                image.resizable().scaledToFill()
                            } else {
                                Image(systemName: "person.crop.circle.fill")
                                    .font(.system(size: 48))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(width: 64, height: 64)
                        .clipShape(Circle())
                    } else {
                        Image(systemName: "person.crop.circle.fill")
                            .font(.system(size: 50))
                            .foregroundStyle(.secondary)
                            .frame(width: 64, height: 64)
                    }

                    VStack(alignment: .leading, spacing: 5) {
                        Text(moumusicServer.profile?.nickname ?? "Echo Music 用户")
                            .font(.title3.weight(.bold))
                            .lineLimit(1)
                        Text("ID 闂?\(moumusicServer.displayID)")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    Image(systemName: moumusicServer.isAdmin ? "checkmark.seal.fill" : "person.crop.circle.badge.checkmark")
                        .font(.title2)
                        .foregroundStyle(moumusicServer.isAdmin ? .orange : Theme.accent)
                }

                Divider()
                HStack {
                    Label("个人资料服务", systemImage: "server.rack")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Text(moumusicServer.statusText)
                        .font(.caption)
                        .foregroundStyle(moumusicServer.config == nil ? .secondary : Theme.accent)
                        .lineLimit(1)
                }

                if moumusicServer.isAdmin {
                    Toggle(isOn: Binding(
                        get: { moumusicServer.config?.downloadsEnabled ?? true },
                        set: { value in Task { await moumusicServer.setDownloadsEnabled(value) } }
                    )) {
                        Label("允许公开下载", systemImage: "arrow.down.circle")
                            .font(.subheadline)
                    }
                    .tint(Theme.accent)
                }
            }
        }

#endif
        return EmptyView()
    }

    private var moumusicIdentityCard: some View {
        MouGlassCard(cornerRadius: 28) {
            ZStack {
                if let local = appearance.cardBackground {
                    ProfileCardBackgroundView(image: local, zoom: appearance.cardZoom,
                                              x: appearance.cardOffsetX, y: appearance.cardOffsetY)
                        .frame(maxWidth: .infinity, minHeight: 180, maxHeight: 260)
                        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                        .overlay(Color.black.opacity(0.26))
                        .allowsHitTesting(false)
                } else if let background = moumusicServer.profile?.backgroundURL,
                   let url = URL(string: background), !background.isEmpty {
                    AsyncImage(url: url) { phase in
                        if case .success(let image) = phase {
                            image.resizable().scaledToFill()
                        } else {
                            Color.clear
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 180, maxHeight: 260)
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .overlay(Color.black.opacity(0.26))
                    .allowsHitTesting(false)
                }

                VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 14) {
                    if let avatar = moumusicServer.profile?.avatarURL, let url = URL(string: avatar) {
                        AsyncImage(url: url) { phase in
                            if case .success(let image) = phase {
                                image.resizable().scaledToFill()
                            } else {
                                Image(systemName: "person.crop.circle.fill")
                                    .font(.system(size: 48))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(width: 64, height: 64)
                        .clipShape(Circle())
                    } else {
                        Image(systemName: "person.crop.circle.fill")
                            .font(.system(size: 50))
                            .foregroundStyle(.secondary)
                            .frame(width: 64, height: 64)
                    }

                    VStack(alignment: .leading, spacing: 5) {
                        Text(moumusicServer.profile?.nickname ?? "Echo Music 用户")
                            .font(.title3.weight(.bold))
                            .lineLimit(1)
                        Text("个人 ID：\(moumusicServer.displayID)")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    Button {
                        showMoumusicProfileEditor = true
                    } label: {
                        Image(systemName: "pencil")
                            .font(.subheadline.weight(.semibold))
                            .frame(width: 36, height: 36)
                            .mouMaterialBackground(.regularMaterial, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("编辑个人资料")
                    Image(systemName: moumusicServer.isAdmin ? "checkmark.seal.fill" : "person.crop.circle.badge.checkmark")
                        .font(.title2)
                        .foregroundStyle(moumusicServer.isAdmin ? .orange : Theme.accent)
                }

                Divider()
                HStack {
                    Label("Echo Music 服务", systemImage: "server.rack")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Text(moumusicServer.statusText)
                        .font(.caption)
                        .foregroundStyle(moumusicServer.config == nil ? .secondary : Theme.accent)
                        .lineLimit(1)
                }

                if let info = moumusicServer.config?.serverInfo {
                    VStack(alignment: .leading, spacing: 4) {
                        if let ipv4 = info.ipv4 { Text("IPv4  \(ipv4)") }
                        if let ipv6 = info.ipv6 { Text("IPv6  \(ipv6)") }
                        HStack(spacing: 12) {
                            if let cpu = info.cpuCores { Text("CPU  \(cpu) cores") }
                            if let memory = info.memoryMB { Text("RAM  \(memory) MB") }
                        }
                        HStack(spacing: 12) {
                            if let storage = info.storageGB { Text("Storage  \(storage) GB") }
                            if let network = info.networkPortMbps { Text("Network  \(network) Mbps") }
                        }
                    }
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                }

                if moumusicServer.isAdmin {
                    Toggle(isOn: Binding(
                        get: { moumusicServer.config?.downloadsEnabled ?? true },
                        set: { value in Task { await moumusicServer.setDownloadsEnabled(value) } }
                    )) {
                            Label("允许公开下载", systemImage: "arrow.down.circle")
                            .font(.subheadline)
                    }
                    .tint(Theme.accent)
                    Button {
                        showMoumusicAdminUsers = true
                    } label: {
                        Label("管理用户资料与 ID", systemImage: "person.2.badge.gearshape")
                    }
                    .foregroundStyle(Theme.accent)
                } else {
                    Button("管理员登录") {
                        showMoumusicAdminLogin = true
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.accent)
                }
                }
            }
        }
    }

    private var aggregateSections: some View {
        VStack(alignment: .leading, spacing: 18) {
            compactIdentity
            accountSourcesCard
            quickLinks
            originalProjectCard
        }
    }

    @ViewBuilder
    private var profilePlatformBadge: some View {
        if bilibiliActive, settings.bilibiliMode != .disabled {
            ZStack {
                Circle().fill(.ultraThinMaterial)
                BrandIconView(name: "BrandBilibili", contentMode: .fill)
                    .frame(width: 42, height: 42)
                    .clipShape(Circle())
            }
            .frame(width: 42, height: 42)
            .clipShape(Circle())
            .overlay { Circle().strokeBorder(.white.opacity(0.55), lineWidth: 2.4) }
        } else {
            HomePlatformBadge(
                platform: settings.homeRecommendationMode == .netease ? .wy : settings.homeRecommendationPlatform
            )
        }
    }

    private var activeProfilePlatform: LXCatalogPlatform {
        settings.homeRecommendationMode == .netease ? .wy : settings.homeRecommendationPlatform
    }

    @ViewBuilder
    private var platformHome: some View {
        if bilibiliActive, settings.bilibiliMode != .disabled {
            bilibiliProfile
            quickLinks
        } else {
            switch activeProfilePlatform {
            case .wy:
                neteaseProfile
            case .kg:
                sessionProfile(
                    name: kugou.profileName,
                    avatar: kugou.avatarURL,
                    loggedIn: kugou.isLoggedIn,
                    vip: kugou.isVIP,
                    brand: "BrandKugou",
                    title: "酷狗音乐",
                    stats: platformStats(level: kugou.level, playlists: nil, hearts: nil, listens: 0, follows: kugou.follows, fans: kugou.fans)
                ) { showKugouLogin = true }
                playlistSectionCard {
                    PlatformAccountPlaylists(platform: .kg)
                }
            case .tx:
                sessionProfile(
                    name: qqMusic.profileName,
                    avatar: qqMusic.avatarURL,
                    loggedIn: qqMusic.isLoggedIn,
                    vip: qqMusic.isVIP == true,
                    brand: "BrandQQ",
                    title: "QQ 音乐",
                    stats: platformStats(level: qqMusic.level, playlists: nil, hearts: nil, listens: 0, follows: qqMusic.follows, fans: qqMusic.fans)
                ) { showQQMusicLogin = true }
                playlistSectionCard {
                    PlatformAccountPlaylists(platform: .tx)
                }
            case .sd:
                sessionProfile(
                    name: qishui.profileName,
                    avatar: qishui.avatarURL,
                    loggedIn: qishui.isLoggedIn,
                    vip: qishui.isVIP,
                    brand: "BrandQishui",
                    title: "汽水音乐",
                    stats: platformStats(level: 0, playlists: nil, hearts: nil, listens: 0, follows: 0, fans: 0)
                ) { showQishuiLogin = true }
            case .mg:
                miguProfile
            default:
                MouGlassCard {
                    Text("\(activeProfilePlatform.displayName) 还没有个人主页，下面这些是本机记录。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            quickLinks
        }
    }

    private var neteaseProfile: some View {
        VStack(alignment: .leading, spacing: 14) {
            MouGlassCard(cornerRadius: 24, padding: 14) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 12) {
                        CachedAsyncImage(url: account.profile?.avatarUrl?.resizedImageURL(192)) {
                            Image(systemName: "person.crop.circle.fill")
                                .resizable().scaledToFit().foregroundStyle(.secondary)
                        }
                        .frame(width: 64, height: 64)
                        .clipShape(Circle())
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                Text(account.profile?.nickname ?? "未登录网易云")
                                    .font(.headline)
                                    .lineLimit(1)
                                if let level = account.profile?.level, level > 0 {
                                    Text("Lv.\(level)")
                                        .font(.system(size: 11, weight: .bold))
                                        .foregroundStyle(Theme.accent)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Theme.accent.opacity(0.14), in: Capsule())
                                }
                            }
                            HStack(spacing: 6) {
                                if account.profile?.hasActiveVIP == true {
                                    PlatformMembershipBadge(title: account.vipLabel ?? "黑胶 VIP")
                                } else {
                                    Text(account.isLoggedIn ? (account.vipLabel ?? "非会员") : "登录后同步歌单和收藏")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            if let uid = account.profile?.userId {
                                Text("uid \(uid)")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        Spacer(minLength: 8)
                        NavigationLink(value: Destination.accountSync) {
                            Image(systemName: account.isLoggedIn ? "checkmark.circle.fill" : "person.badge.plus")
                                .font(.title3)
                                .foregroundStyle(account.isLoggedIn ? .green : Theme.accent)
                        }
                        .accessibilityLabel(account.isLoggedIn ? "查看账号同步" : "登录网易云")
                    }
                    if let signature = account.profile?.signature, !signature.isEmpty {
                        Text(signature)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                    }
                    profileStatRow(platformStats(
                        level: account.profile?.level ?? 0,
                        playlists: account.userPlaylists.count,
                        hearts: account.likedTrackIDs.count,
                        listens: account.profile?.listenSongs ?? 0,
                        follows: account.profile?.follows ?? 0,
                        fans: account.profile?.followeds ?? 0
                    ))
                }
            }
            if account.isLoggedIn {
                let favorites = account.userPlaylists.filter(\.isLikedSongsList)
                playlistSectionCard {
                    VStack(alignment: .leading, spacing: 18) {
                        playlistGroup("我喜欢的音乐", favorites)
                        playlistGroup("收藏的歌单", Array(account.subscribedPlaylists.prefix(8)))
                        playlistGroup("我创建的歌单", Array(account.createdPlaylists.prefix(8)))
                    }
                }
            }
        }
        .task {
            guard account.isLoggedIn else { return }
            await account.refreshLibrary()
        }
    }

    private func sessionProfile(
        name: String?,
        avatar: String?,
        loggedIn: Bool,
        vip: Bool,
        brand: String,
        title: String,
        stats: [ProfileStat] = [],
        login: @escaping () -> Void
    ) -> some View {
        MouGlassCard(cornerRadius: 24, padding: 14) {
            VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Group {
                    if loggedIn, let avatar {
                        CachedAsyncImage(url: avatar.resizedImageURL(176)) {
                            BrandIconView(name: brand)
                        }
                    } else {
                        BrandIconView(name: brand)
                    }
                }
                .frame(width: 44, height: 44)
                .clipShape(Circle())
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(loggedIn ? (name ?? title) : "未登录\(title)")
                            .font(.headline)
                            .lineLimit(1)
                        if loggedIn, vip { PlatformMembershipBadge(title: "豪华绿钻") }
                    }
                    Text(loggedIn ? (vip ? "会员" : "非会员") : "登录后同步这个平台的歌单")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Button(action: login) {
                    Image(systemName: loggedIn ? "arrow.clockwise" : "person.badge.plus")
                        .font(.title3)
                        .foregroundStyle(loggedIn ? .green : Theme.accent)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(loggedIn ? "重新登录\(title)" : "登录\(title)")
            }
            if loggedIn, !stats.isEmpty {
                profileStatRow(stats)
            }
            }
        }
    }

    /// 咪咕音乐：登录走官方网页并保存会话；曲库与播放仍使用公开接口。
    private var miguProfile: some View {
        MouGlassCard(cornerRadius: 24, padding: 14) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    BrandIconView(name: "BrandMigu")
                        .frame(width: 44, height: 44)
                        .clipShape(Circle())
                    VStack(alignment: .leading, spacing: 4) {
                        Text(migu.isLoggedIn ? (migu.profileName ?? "咪咕音乐") : "未登录咪咕音乐")
                            .font(.headline)
                            .lineLimit(1)
                        Text(migu.isLoggedIn ? "账号会话已保存" : "登录后可保存咪咕账号会话")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Button {
                        showMiguLogin = true
                    } label: {
                        Image(systemName: migu.isLoggedIn ? "arrow.clockwise" : "person.badge.plus")
                            .font(.title3)
                            .foregroundStyle(migu.isLoggedIn ? .green : Theme.accent)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(migu.isLoggedIn ? "重新登录咪咕音乐" : "登录咪咕音乐")
                }
                Text("咪咕音乐使用公开曲库搜索与播放；登录只保存账号会话，歌单同步暂未开放。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if migu.isLoggedIn {
                    Button(role: .destructive) {
                        migu.signOut()
                    } label: {
                        Text("退出咪咕登录").frame(maxWidth: .infinity, minHeight: 40)
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
    }

    private var bilibiliProfile: some View {
        VStack(alignment: .leading, spacing: 14) {
            MouGlassCard(cornerRadius: 24, padding: 14) {
                HStack(spacing: 12) {
                    Group {
                        if bilibili.isLoggedIn, let avatar = bilibili.avatarURL {
                            CachedAsyncImage(url: avatar.resizedImageURL(176)) {
                                BrandIconView(name: "BrandBilibili")
                            }
                        } else {
                            BrandIconView(name: "BrandBilibili")
                        }
                    }
                    .frame(width: 44, height: 44)
                    .clipShape(Circle())
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text(bilibili.isLoggedIn ? (bilibili.profileName ?? "哔哩哔哩") : "未登录哔哩哔哩")
                                .font(.headline)
                                .lineLimit(1)
                            if bilibili.isLoggedIn, let title = bilibili.membershipTitle {
                                PlatformMembershipBadge(title: title)
                            }
                            if bilibili.isLoggedIn, bilibili.level > 0 {
                                Text("Lv.\(bilibili.level)")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(Theme.accent)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Theme.accent.opacity(0.14), in: Capsule())
                            }
                        }
                        if !bilibili.isLoggedIn {
                            Text("登录后同步账号资料")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else if bilibili.membershipTitle == nil {
                            Text("非会员")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button {
                        if bilibili.isLoggedIn { signedInTarget = .bilibili } else { showBilibiliLogin = true }
                    } label: {
                        Image(systemName: bilibili.isLoggedIn ? "person.crop.circle" : "person.badge.plus")
                            .font(.title3)
                            .foregroundStyle(bilibili.isLoggedIn ? .green : Theme.accent)
                    }
                    .buttonStyle(.plain)
                }
                if bilibili.isLoggedIn {
                    profileStatRow(platformStats(
                        level: bilibili.level, playlists: nil, hearts: nil, listens: 0,
                        follows: bilibili.following, fans: bilibili.fans
                    ))
                }
            }
            BilibiliCloudPlaylistsCard()
        }
    }

    private var accountSourcesCard: some View {
        MouGlassCard(padding: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Label("账号音源与同步", systemImage: "person.2.wave.2")
                    .font(.headline.weight(.semibold))
                    .padding(.horizontal, 4)
                    .padding(.bottom, 4)

                accountSourceRow(
                    title: "网易云音乐",
                    subtitle: account.isLoggedIn ? ((account.profile?.nickname ?? "已登录") + (" · " + (account.vipLabel ?? "非会员"))) : "未登录 · 同步歌单与播放记录",
                    icon: "music.note",
                    isLoggedIn: account.isLoggedIn,
                    action: { openLogin() },
                    destination: .accountSync
                )

                Divider().padding(.leading, 48)

                accountSourceRow(
                    title: "QQ 音乐",
                    subtitle: qqMusic.isLoggedIn ? ((qqMusic.profileName ?? "已登录") + (qqMusic.isVIP == nil ? "" : (qqMusic.isVIP == true ? " · 会员" : " · 非会员"))) : "未登录 · 扫码同步账号资料",
                    icon: "music.quarternote.3",
                    isLoggedIn: qqMusic.isLoggedIn
                ) {
                    if qqMusic.isLoggedIn { signedInTarget = .qq } else { showQQMusicLogin = true }
                }
                Divider().padding(.leading, 48)

                accountSourceRow(
                    title: "酷狗音乐",
                    subtitle: kugou.isLoggedIn ? ((kugou.profileName ?? "已登录") + (kugou.isVIP ? " · 会员" : " · 非会员")) : "未登录 · 扫码同步账号资料",
                    icon: "headphones",
                    isLoggedIn: kugou.isLoggedIn
                ) {
                    if kugou.isLoggedIn { signedInTarget = .kugou } else { showKugouLogin = true }
                }
                Divider().padding(.leading, 48)

                accountSourceRow(
                    title: "汽水音乐",
                    subtitle: qishui.isLoggedIn
                        ? ((qishui.profileName ?? "已登录") + (qishui.isVIP ? " · 会员" : " · 非会员"))
                        : "未登录 · 抖音扫码，未登录只有试听",
                    icon: "drop.fill",
                    isLoggedIn: qishui.isLoggedIn
                ) {
                    showQishuiLogin = true
                }
                if settings.bilibiliMode != .disabled {
                Divider().padding(.leading, 48)

                accountSourceRow(
                    title: "哔哩哔哩",
                    subtitle: bilibili.isLoggedIn ? ((bilibili.profileName ?? "已登录") + " · " + (bilibili.membershipTitle ?? "非会员")) : "未登录 · 同步账号资料与视频服务",
                    icon: "play.rectangle.fill",
                    isLoggedIn: bilibili.isLoggedIn
                ) {
                    if bilibili.isLoggedIn { signedInTarget = .bilibili } else { showBilibiliLogin = true }
                }
                }

                Text("点已登录的平台可退出登录或同步歌单。QQ 音乐和酷狗的头像在推荐页右上角，哔哩哔哩仍在这里管理。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 6)
                    .padding(.top, 10)
            }
        }
    }

    @ViewBuilder
    private func accountMark(title: String, icon: String, isLoggedIn: Bool) -> some View {
        let brand: String? = {
            if title.contains("网易") { return "BrandNetease" }
            if title.contains("QQ") { return "BrandQQ" }
            if title.contains("酷狗") { return "BrandKugou" }
            if title.contains("哔哩") { return "BrandBilibili" }
            return nil
        }()
        if let brand {
            BrandIconView(name: brand).frame(width: 30, height: 30)
        } else {
            Image(systemName: icon)
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(isLoggedIn ? .green : Theme.accent)
                .frame(width: 30)
        }
    }

    @ViewBuilder
    private func accountSourceRow(
        title: String,
        subtitle: String,
        icon: String,
        isLoggedIn: Bool,
        action: @escaping () -> Void,
        destination: Destination? = nil
    ) -> some View {
        let row = HStack(spacing: 12) {
            accountMark(title: title, icon: icon, isLoggedIn: isLoggedIn)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.body.weight(.semibold))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Image(systemName: isLoggedIn ? "checkmark.circle.fill" : "chevron.right")
                .foregroundStyle(isLoggedIn ? .green : .secondary)
        }
        .contentShape(Rectangle())
        .frame(minHeight: 58)

        if let destination {
            NavigationLink(value: destination) {
                row
            }
            .buttonStyle(.plain)
        } else {
            Button(action: action) {
                row
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private func playlistGroup(_ title: String, _ playlists: [PlaylistSummary]) -> some View {
        if !playlists.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text(title)
                    .font(.headline.weight(.semibold))
                ForEach(playlists) { playlist in
                    NavigationLink(value: Destination.playlist(playlist.id)) {
                        HStack(spacing: 12) {
                            CachedAsyncImage(url: playlist.coverURL?.resizedImageURL(160)) {
                                RoundedRectangle(cornerRadius: 8).fill(.secondary.opacity(0.2))
                            }
                            .frame(width: 48, height: 48)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(playlist.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                                Text("\(playlist.trackCount) 首").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func playlistSectionCard<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(14)
            .background(.ultraThinMaterial,
                        in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private struct ProfileStat: Identifiable {
        let title: String
        let value: String
        var id: String { title }
    }

    /// Hide a count the platform did not return. A real zero still shows for
    /// playlists and hearts, which are loaded locally.
    private func platformStats(level: Int, playlists: Int?, hearts: Int?, listens: Int, follows: Int, fans: Int) -> [ProfileStat] {
        var items: [ProfileStat] = []
        if level > 0 { items.append(.init(title: "等级", value: "Lv.\(level)")) }
        if let playlists { items.append(.init(title: "歌单", value: "\(playlists)")) }
        if let hearts { items.append(.init(title: "红心", value: "\(hearts)")) }
        if listens > 0 { items.append(.init(title: "听歌", value: "\(listens)")) }
        if follows > 0 { items.append(.init(title: "关注", value: "\(follows)")) }
        if fans > 0 { items.append(.init(title: "粉丝", value: "\(fans)")) }
        return items
    }

    private func profileStatRow(_ items: [ProfileStat]) -> some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
            ForEach(items) { item in
                metric(title: item.title, value: item.value)
            }
        }
    }

    private func metric(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value)
                .font(.headline.weight(.bold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var quickLinks: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
            profileTile("红心歌曲", icon: "heart.fill", tint: .pink, destination: .likedSongs)
            profileTile("最近播放", icon: "clock.fill", tint: .orange, destination: .recents)
            NavigationLink {
                ListeningRankView()
            } label: {
                profileTileLabel("听歌排行", icon: "chart.bar.fill", tint: .purple)
            }
            .buttonStyle(.plain)
            NavigationLink {
                ListeningReportView()
            } label: {
                profileTileLabel("听歌报告", icon: "waveform.path.ecg", tint: Theme.accent)
            }
            .buttonStyle(.plain)
            profileTile("收藏", icon: "bookmark.fill", tint: .yellow, destination: .collections)
            Button { showDownloads = true } label: {
                profileTileLabel("下载管理", icon: "arrow.down.circle.fill", tint: .blue)
            }
            .buttonStyle(.plain)
            NavigationLink {
                WorkoutView()
            } label: {
                profileTileLabel("锻炼", icon: "figure.run", tint: .green)
            }
            .buttonStyle(.plain)
            NavigationLink {
                SupportView()
            } label: {
                profileTileLabel("赞助与支持", icon: "heart.fill", tint: .pink)
            }
            .buttonStyle(.plain)
            NavigationLink {
                AudioDevicesView()
            } label: {
                profileTileLabel("音频设备", tint: .teal) {
                    HeadphoneCaseGlyph()
                        .frame(width: 22, height: 22)
                        .foregroundStyle(Color.teal)
                }
            }
            .buttonStyle(.plain)
        }
    }

    private func profileTile(_ title: String, icon: String, tint: Color, destination: Destination) -> some View {
        NavigationLink(value: destination) {
            profileTileLabel(title, icon: icon, tint: tint)
        }
        .buttonStyle(.plain)
    }

    private func profileTileLabel(_ title: String, icon: String, tint: Color) -> some View {
        profileTileLabel(title, tint: tint) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(tint)
        }
    }

    private func profileTileLabel<Icon: View>(_ title: String, tint: Color,
                                              @ViewBuilder icon: () -> Icon) -> some View {
        VStack(spacing: 8) {
            icon()
                .frame(width: 36, height: 36)
                .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .multilineTextAlignment(.center)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, minHeight: 92)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var appearanceCard: some View {
        MouGlassCard {
            VStack(alignment: .leading, spacing: 12) {
                Label("外观", systemImage: "circle.lefthalf.filled")
                    .font(.headline.weight(.semibold))
                Picker("外观", selection: $settings.appearance) {
                    ForEach(AppAppearance.allCases) { appearance in
                        Text(appearance.displayName).tag(appearance)
                    }
                }
                .pickerStyle(.segmented)
                Text("外观设置会同步应用、播放器和设置页面。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var originalProjectCard: some View {
        MouGlassCard {
            HStack(spacing: 12) {
                Image(systemName: "info.circle")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text("原项目地址")
                        .font(.system(size: 14, weight: .semibold))
                    Text(verbatim: "https://github.com/jiajia2222/Moumusic")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
                Spacer(minLength: 8)
                Button {
                    UIPasteboard.general.string = "https://github.com/jiajia2222/Moumusic"
                    ToastCenter.shared.show("已复制原项目地址")
                    Haptics.tap()
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Theme.accent)
                        .frame(width: 34, height: 34)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("复制原项目地址")
            }
        }
    }
}

private struct ListeningRibbon: View {
    let days: [(label: String, minutes: Double)]
    @Binding var selected: Int?

    var body: some View {
        let peak = max(days.map(\.minutes).max() ?? 1, 1)
        // 一个月视图里每根柱子只有几像素宽，逐条数值会被挤成竖排并裁切。
        let dense = days.count > 10
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .bottom, spacing: 8) {
                ForEach(Array(days.enumerated()), id: \.offset) { index, day in
                    let ratio = peak > 0 ? min(day.minutes / peak, 1) : 0
                    let active = selected == index
                    VStack(spacing: 8) {
                        Group {
                            if !dense, day.minutes > 0 {
                                Text(ListeningRibbon.shortDuration(day.minutes))
                                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                                    .foregroundStyle(active ? Theme.accent : .secondary)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.6)
                            } else {
                                Color.clear
                            }
                        }
                        .frame(height: 11)
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: day.minutes > 0
                                        ? [Theme.accent.opacity(active ? 1 : 0.78), Theme.accent.opacity(active ? 0.55 : 0.28)]
                                        : [Color.primary.opacity(0.08), Color.primary.opacity(0.04)],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                            .frame(height: max(8, 92 * ratio))
                            .shadow(color: active ? Theme.accent.opacity(0.28) : .clear, radius: 8, y: 3)
                            .overlay {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .strokeBorder(Color.white.opacity(active ? 0.28 : 0.08), lineWidth: 1)
                            }
                        Text(day.label)
                            .font(.system(size: 10, weight: active ? .semibold : .medium))
                            .foregroundStyle(active ? .primary : .secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                            selected = active ? nil : index
                        }
                    }
                    .accessibilityLabel("\(day.label) \(Int(day.minutes)) 分钟")
                }
            }
            .frame(height: 132, alignment: .bottom)
            if let selected, days.indices.contains(selected) {
                Text("\(days[selected].label) · \(ListeningRibbon.duration(days[selected].minutes))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("柱高代表当天听了多久，点一下看具体时长")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    static func shortDuration(_ minutes: Double) -> String {
        if minutes >= 60 {
            return String(format: "%.1fh", minutes / 60)
        }
        return "\(Int(minutes.rounded()))m"
    }

    static func duration(_ minutes: Double) -> String {
        let total = max(0, Int((minutes * 60).rounded()))
        let hours = total / 3600
        let mins = (total % 3600) / 60
        if hours > 0 { return "\(hours)小时\(mins)分" }
        return "\(mins)分钟"
    }
}

private enum ListeningBlockSpan { case threeDays, week, month, custom }

private struct ListeningReportView: View {
    @ObservedObject private var stats = ListeningStatsStore.shared
    @State private var selectedDay: Int?
    @State private var blockSpan: ListeningBlockSpan = .week
    @State private var blockStart = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
    @State private var blockEnd = Date()
    @State private var showBlockRange = false

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                VStack(spacing: 6) {
                    Text(stats.formattedDuration)
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                    Text("累计听歌")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 22)

                VStack(spacing: 10) {
                    HStack(spacing: 10) {
                        reportTile("播放", "\(stats.totalPlayCount)", "play.fill", wide: true)
                        reportTile("连续", "\(stats.streakDays) 天", "flame")
                    }
                    HStack(spacing: 10) {
                        reportTile("今日", minutesText(todayMinutes), "sun.max")
                        reportTile("日均", minutesText(averageMinutes), "chart.bar")
                    }
                    HStack(spacing: 10) {
                        reportTile("近 7 天", minutesText(weekMinutes), "calendar", wide: true)
                        reportTile("最久一天", minutesText(peakMinutes), "star")
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)

                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text("聆听分布")
                            .font(.headline.weight(.semibold))
                        Spacer()
                        Menu {
                            Button("近三天") { blockSpan = .threeDays }
                            Button("近七天") { blockSpan = .week }
                            Button("近一个月") { blockSpan = .month }
                            Button("自选区间") {
                                blockSpan = .custom
                                showBlockRange = true
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Text(blockTitle)
                                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                            }
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        }
                    }
                    ListeningRibbon(days: blockDays, selected: $selectedDay)
                }
                .padding(16)
            }
        }
        .sheet(isPresented: $showBlockRange) {
            NavigationStack {
                Form {
                    DatePicker("开始", selection: $blockStart, displayedComponents: .date)
                    DatePicker("结束", selection: $blockEnd, displayedComponents: .date)
                }
                .navigationTitle("自选区间")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("完成") { showBlockRange = false }
                    }
                }
            }
            .presentationDetents([.medium])
        }
        .navigationTitle("听歌报告")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func reportTile(_ title: String, _ value: String, _ symbol: String, wide: Bool = false) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .frame(width: 30, height: 30)
                .background(Theme.accent.opacity(0.12), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(value)
                    .font(.system(size: wide ? 20 : 16, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func reportMetric(_ title: String, _ value: String) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.system(size: 16, weight: .bold, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var reportDivider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.08))
            .frame(width: 1, height: 28)
    }

    private var blockTitle: String {
        switch blockSpan {
        case .threeDays: return "近三天"
        case .week: return "近七天"
        case .month: return "近一个月"
        case .custom: return "自选区间"
        }
    }

    private var blockDays: [(label: String, minutes: Double)] {
        let calendar = Calendar.current
        let symbols = ["日", "一", "二", "三", "四", "五", "六"]
        let end = calendar.startOfDay(for: blockSpan == .custom ? max(blockStart, blockEnd) : Date())
        let count: Int
        switch blockSpan {
        case .threeDays: count = 3
        case .week: count = 7
        case .month: count = 30
        case .custom:
            let start = calendar.startOfDay(for: min(blockStart, blockEnd))
            count = min(max(calendar.dateComponents([.day], from: start, to: end).day ?? 0, 0) + 1, 42)
        }
        return (0..<count).map { offset in
            let date = calendar.date(byAdding: .day, value: -(count - 1 - offset), to: end) ?? end
            let weekday = calendar.component(.weekday, from: date) - 1
            let label = count <= 7 ? symbols[weekday] : "\(calendar.component(.day, from: date))"
            return (label, stats.minutes(on: date))
        }
    }

    private var week: [(label: String, minutes: Double)] { stats.lastSevenDays() }
    private var weekMinutes: Double { week.reduce(0) { $0 + $1.minutes } }
    private var todayMinutes: Double { week.last?.minutes ?? 0 }
    private var averageMinutes: Double { week.isEmpty ? 0 : weekMinutes / Double(week.count) }
    private var peakMinutes: Double { week.map(\.minutes).max() ?? 0 }

    private func barHeight(_ minutes: Double) -> CGFloat {
        let peak = max(week.map(\.minutes).max() ?? 0, 1)
        return max(4, CGFloat(minutes / peak) * 86)
    }

    private func minutesText(_ minutes: Double) -> String {
        let total = Int(minutes.rounded())
        if total >= 60 { return "\(total / 60)小时\(total % 60)分" }
        return "\(total)分钟"
    }

    /// Bar values are stored in minutes; the tap label needs the leftover seconds.
    private func durationText(_ minutes: Double) -> String {
        let total = max(0, Int((minutes * 60).rounded()))
        let hours = total / 3600
        let mins = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 { return "\(hours)时\(mins)分\(secs)秒" }
        return "\(mins)分\(secs)秒"
    }
}

private struct MoumusicProfileEditorView: View {
    private func positionSlider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        HStack {
            Text(title).frame(width: 72, alignment: .leading)
            Slider(value: value, in: range)
        }
    }

    @EnvironmentObject private var server: MoumusicServerStore
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var appearance = ProfileAppearanceStore.shared
    @State private var cardItem: PhotosPickerItem?
    @State private var nickname = ""
    @State private var backgroundURL = ""
    @State private var signature = ""
    @State private var isSaving = false

    var body: some View {
        NavigationStack {
            Form {
                Section("个人资料") {
                    TextField("昵称", text: $nickname)
                    TextField("个性签名", text: $signature, axis: .vertical)
                        .lineLimit(2...4)
                }

                Section("个人卡片背景") {
                    PhotosPicker(selection: $cardItem, matching: .images) {
                        Label(appearance.cardBackground == nil ? "从相册选择图片" : "更换图片", systemImage: "photo.on.rectangle")
                    }
                    if let local = appearance.cardBackground {
                        ProfileCardBackgroundView(image: local, zoom: appearance.cardZoom,
                                                  x: appearance.cardOffsetX, y: appearance.cardOffsetY)
                            .frame(maxWidth: .infinity)
                            .frame(height: 150)
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        positionSlider("缩放", value: $appearance.cardZoom, range: 1...3)
                        positionSlider("水平位置", value: $appearance.cardOffsetX, range: -1...1)
                        positionSlider("垂直位置", value: $appearance.cardOffsetY, range: -1...1)
                        Button("还原位置") {
                            appearance.cardZoom = 1
                            appearance.cardOffsetX = 0
                            appearance.cardOffsetY = 0
                        }
                        Button("移除相册图片", role: .destructive) { appearance.resetCardBackground() }
                    }
                    TextField("或填写图片 URL", text: $backgroundURL)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)

                    if let url = URL(string: backgroundURL), !backgroundURL.isEmpty {
                        AsyncImage(url: url) { phase in
                            if case .success(let image) = phase {
                                image.resizable().scaledToFill()
                            } else {
                                Color.secondary.opacity(0.12)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 130)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }

                    Text("保存后会用于 Echo Music 个人 ID 卡片。建议使用稳定的 HTTPS 图片地址。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("编辑个人卡片")
            .navigationBarTitleDisplayMode(.inline)
            .onChange(of: cardItem) { item in
                guard let item else { return }
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self) { appearance.setCardBackground(data) }
                    cardItem = nil
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        isSaving = true
                        Task {
                            await server.updateProfile(
                                nickname: nickname.trimmingCharacters(in: .whitespacesAndNewlines),
                                signature: signature.trimmingCharacters(in: .whitespacesAndNewlines),
                                backgroundURL: backgroundURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                    ? nil
                                    : backgroundURL.trimmingCharacters(in: .whitespacesAndNewlines)
                            )
                            isSaving = false
                            dismiss()
                        }
                    }
                    .disabled(isSaving || nickname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .overlay {
                if isSaving {
                    ProgressView()
                        .padding(20)
                        .mouMaterialBackground(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                }
            }
            .task {
                guard let profile = server.profile else { return }
                nickname = profile.nickname
                signature = profile.signature ?? ""
                backgroundURL = profile.backgroundURL ?? ""
            }
        }
    }
}
#endif

/// 赞助页。收款码打进程序包，避免资源目录没被打包时图片空白。
private struct SupportView: View {
    @State private var saved = false
    private var code: UIImage? { SupportCode.image }

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                VStack(spacing: 8) {
                    Text("感谢支持")
                        .font(.system(size: 34, weight: .semibold, design: .serif))
                    Text("如果 Echo Music 对你有帮助，欢迎请开发者喝一杯咖啡。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                if let code {
                    Image(uiImage: code)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 280)
                        .padding(16)
                        .background(.white, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
                        .shadow(color: .black.opacity(0.12), radius: 24, y: 12)
                        .contextMenu {
                            Button { save(code) } label: {
                                Label("保存到相册", systemImage: "square.and.arrow.down")
                            }
                        }
                }
                VStack(spacing: 6) {
                    Text("长按图片即可保存到相册，再用微信扫码赞赏。")
                    Text("建议在备注里留下你的名字、账号或 UID，方便后续回馈。")
                    Text("赞赏完全自愿，不影响任何功能。")
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            }
            .padding(28)
        }
        .background(
            LinearGradient(colors: [Color(.systemBackground), Color(.secondarySystemBackground)],
                           startPoint: .top, endPoint: .bottom)
            .ignoresSafeArea()
        )
        .navigationTitle("赞助与支持")
        .navigationBarTitleDisplayMode(.inline)
        .alert("已保存到相册", isPresented: $saved) {
            Button("好", role: .cancel) {}
        }
    }

    private func save(_ image: UIImage) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else { return }
            UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
            DispatchQueue.main.async { saved = true }
        }
    }
}

private enum SupportCode {
    static let image: UIImage? = {
        guard let data = Data(base64Encoded: png), !data.isEmpty else { return nil }
        return UIImage(data: data)
    }()

    private static let png = "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"
}

/// Moving highlight sweep across the exclusive-ID capsule (Beans-style shine).
private struct GoldShimmer: View {
    @State private var phase: CGFloat = -1

    var body: some View {
        GeometryReader { geo in
            LinearGradient(colors: [.clear, .white.opacity(0.55), .clear], startPoint: .leading, endPoint: .trailing)
                .frame(width: geo.size.width * 0.55)
                .offset(x: phase * geo.size.width)
                .blendMode(.plusLighter)
        }
        .onAppear {
            phase = -0.6
            withAnimation(.linear(duration: 2.2).repeatForever(autoreverses: false)) { phase = 1.1 }
        }
    }
}

/// 参考耳机充电盒轮廓二次创作的图标：圆角盒身、开盖缝、指示灯。
private struct HeadphoneCaseGlyph: View {
    var body: some View {
        Canvas { context, size in
            let width = size.width
            let height = size.height
            let stroke = StrokeStyle(lineWidth: max(1.3, width * 0.075),
                                     lineCap: .round, lineJoin: .round)
            let body = CGRect(x: width * 0.10, y: height * 0.28,
                              width: width * 0.80, height: height * 0.52)
            context.stroke(Path(roundedRect: body, cornerRadius: height * 0.16),
                           with: .foreground, style: stroke)

            var seam = Path()
            seam.move(to: CGPoint(x: body.minX + width * 0.02, y: body.midY - height * 0.01))
            seam.addLine(to: CGPoint(x: body.maxX - width * 0.02, y: body.midY - height * 0.01))
            context.stroke(seam, with: .foreground, style: stroke)

            var tab = Path()
            tab.move(to: CGPoint(x: width * 0.38, y: body.midY - height * 0.01))
            tab.addLine(to: CGPoint(x: width * 0.62, y: body.midY - height * 0.01))
            context.stroke(tab, with: .foreground,
                           style: StrokeStyle(lineWidth: max(2.0, width * 0.10), lineCap: .round))

            let dot = CGRect(x: width * 0.485, y: body.midY + height * 0.12,
                             width: width * 0.03, height: width * 0.03)
            context.fill(Path(ellipseIn: dot), with: .foreground)
        }
    }
}
