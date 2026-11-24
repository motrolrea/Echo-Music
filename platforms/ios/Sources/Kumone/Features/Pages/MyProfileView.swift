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
    @Environment(\.openLogin) private var openLogin
    @StateObject private var syncStore = ListeningSyncStore.shared
    @StateObject private var moumusicServer = MoumusicServerStore.shared
    @State private var showDownloads = false
    @State private var showMoumusicAdminLogin = false
    @State private var showMoumusicAdminUsers = false
    @State private var showQQMusicLogin = false
    @State private var showKugouLogin = false
    @State private var showQishuiLogin = false
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
                        ForEach(LXCatalogPlatform.catalogueCases.filter { $0 != .aggregate && $0 != .sd }) { platform in
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
        VStack(alignment: .leading, spacing: 10) {
            GeometryReader { geo in
                let width = geo.size.width
                let total = max(days.reduce(0) { $0 + max($1.minutes, 0.35) }, 0.35)
                HStack(spacing: 3) {
                    ForEach(Array(days.enumerated()), id: \.offset) { index, day in
                        let share = max(day.minutes, 0.35) / total
                        let active = selected == index
                        Capsule()
                            .fill(day.minutes > 0
                                  ? Theme.accent.opacity(0.28 + 0.72 * day.minutes / peak)
                                  : Color.primary.opacity(0.08))
                            .frame(width: max(width * share - 3, 6))
                            .overlay {
                                if active {
                                    Capsule().strokeBorder(Color.primary, lineWidth: 1.5)
                                }
                            }
                            .onTapGesture {
                                withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                                    selected = active ? nil : index
                                }
                            }
                            .accessibilityLabel("\(day.label) \(Int(day.minutes)) 分钟")
                    }
                }
            }
            .frame(height: 46)
            if let selected, days.indices.contains(selected) {
                Text("\(days[selected].label) · \(ListeningRibbon.duration(days[selected].minutes))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("每一段的宽度是这天听了多久")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
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
    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                if let image = SupportCode.image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 280)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .shadow(color: .black.opacity(0.08), radius: 16, y: 8)
                }
                VStack(spacing: 8) {
                    Text("感谢你的支持")
                        .font(.title3.weight(.semibold))
                    Text("使用微信扫码即可赞赏。建议在备注里留下你的名字、账号或 UID，方便后续回馈。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Text("赞赏完全自愿，不影响任何功能。")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(24)
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .navigationTitle("赞助与支持")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private enum SupportCode {
    static let image: UIImage? = {
        guard let data = Data(base64Encoded: jpeg), !data.isEmpty else { return nil }
        return UIImage(data: data)
    }()

    private static let jpeg = "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oSCK4vw5r0Xh60fTdWtZoZonZshAd2fx/I9MV3tNcL/GF9qAPOvE+oXWq3WmXRt3t7MylYPM4duVJYj06Yrc+Jv/ACL0X/Xwv/oLV1fX6UtAFez/AOPWL/rmv8q5fxVZ3dlrFvr2nQ+eYV2yxjr3GfyOPbrXYUdKAOSbx5pxh/dW9zJOeBEAOvpnNanhybVbmy8/WI44Xc5SJQQUX/az3rWCIDkKAT3xS49zQByHhD/katf/AOurf+hmtrxb/wAi1qH/AFyNawFLQBheB/8AkV7H/gf/AKG1blLRQB55qhvI/iDdT6eglnt41l8s9ZFCKGA9yDWpceOrFIWENvdfa/uiF0xtb359afb2lz/wsC5u/Ik+ztEAJNp2k7FHXpXT7BuztXPrigDmvA+k3VnHcX2oIVurxt5DdQMk8+hyelZcc58M+KL+41GCR4L12ZJkGeN27H64IrvB60cEfN37GgDhfEmvPrWizpplvL9lTBnnlXaMAjCr1yScVr6d/wAk/P8A15Sf+gmukCgDAAFLQBzfw8/5FmH/AH3/AJ1Z8af8ivff7g/9CFbdFAHMaLpkGqeC7S0uFGx49wYDlWyfmHvVPwzqM+kX50DViQyn9xIehB6DPv29+K7OigBKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAWiiigAooooASiiigAooooAKKKKACg0UUxiHpXges27WmrXUDDBSZ1/Wvfa88+JHheSWY6tYRlzj9+ijnj+IfhXVhZqMrPqc1ePMro86ooor1DgCiiigAooooA9P8AhP8A8gW4/wCvg/yFdF4lt7u50x47CR0lLKfkfaSAckZyOv1H1rxW1vLq1Xbb3U8IJywjkZc/kakOqah/z/3f/f5/8a4J4Zyk3c6o1eVWsehPo/id9v8ApzxSLAFBFwSoIXBBGeSTzuxn3p8Oi63/ABXdyqplokN03B3oeTk7hgP94nrXnP8Aamof8/11/wB/m/xo/tS//wCf+6z/ANdm/wAan6p5le3XY9ou7D7Tqdrcso2xq6OST0I6CqcmnTRaPbWsdukzxIF2u3yDBBzt6EjtmvI/7V1D/n/u/wDv83+NH9q6h/z/AN3/AN/m/wAaPqnmP267Hq1npUsF5ZmK28pYG3NISpL/ACFecDO4dBzjFNSz1K5kdvMnijaUiTM7DcvmqRtAPy4UEcdQa8r/ALV1D/n/ALv/AL/N/jR/al+P+X67/wC/zf40fVPMPbrsex6DZ3Vn5n2mZ5AwXG+Uuc8569O1Z3xM/wCRSn/66R/+hCvLf7U1D/oIXY/7bv8A402W9u7hCk11cSqcEq8pb+ZNOOFcZJ3JlXUlaw/R7c3eq2kCjJkmVfzNe+DpXnnw48LyxSrq2oRbDt/cIRyM/wAR/DpXoWeKyxU1KVl0NKEGlqLRSUVynQLRSUUALRSUUALRSUUAFGaKKADNFFFAC0UmaM0ALRSUUALRSUUALRSUUALRSUUAFGaKKAFopM0ZoAWikooAWikooAWikooAKM0UUALmjNJRQAuaXNNooAXNGaSigBc0ZpKKAFopM0ZoAWikooAXNGaSigBc0ZpKKAFzRmkooAWikooAWikooAWikooAWikooAWikooAWikooAWikooAWikooAWikooAWikooAWikooAWikooAWikooAWikooAWikooAWikooAWikooAWikooAWikooAWikooAWikooAWikooAWikooAWikooAWikooAWikooAWikooAWikooAWikooAWikooAWikooAWikooAWiiigAooooAWim0UAOooooAKKKKACiiigAooooAKKKKAFopKKACiiigAooooASikJozQAUUUUALRTaM0AYmp+ENF1KQyT2YWVurxEoT9ccVlSfDfRG6SXi/wC7Iv8AUV2GaM1oqs1omQ6cXujjP+FaaR/z8X3/AH2n/wATR/wrTSP+fm+/77T/AOJrs80hNP21TuL2UOxxv/CtdH/5+b7/AL7T/wCJo/4Vro//AD833/faf/E12OaM0e2qdw9lDscd/wAK10f/AJ+r/wD77T/4mj/hWujf8/V//wB9p/8AE12NFHtqncPZQ7HHf8K00b/n5vv++0/+Jo/4Vpo3/Pzff99p/wDE12NFHtqncPZQ7HHf8K00b/n6v/8AvtP/AImj/hWmjf8AP1f/APfaf/E12NFHtqncPZQ7HHf8K00b/n6v/wDvtP8A4mj/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0rGmq3lq0rfdXp7mgCO8k8qMQofmP3z/AEqmKViXck9ScmnotUiGxmKjboamYYJpoHFNy0ElqRxSZ6DBFP3jPPU0FQe2CaCg79qg0CRz/CtCsSMdKXjHAoA5zQAhznrQpPTrTz0ximjHUDmgAwRkg02PcM55pxww9KNuDwaQCEmk3U/60hApgJuyKQdaPpTc81RLH0opmaUGqJJVNSqagU81KhrSLIZNH1q/F90VQi61fi+6KJlRJlqK6uIbcRm4ljiDuI13uF3MeAoz1J9KlWvLvj94Ml17w4utaYZRqejAzKEY5kjHLYx/EMbgRzwR3Fc5qekajfQabp9zf3kmy2tY3mlfaTsRQSTxycAdqzPDPifSfFumSahoNy1zbRymFpDG6fOACRhgD0YVxGg+L5PGXwO1q8uwRe2+mXVvckrgSMsLfOO3IwTjocisj9nnU7fSPhPq+oXhYQWt7PLJtGTtWKInA7mgD1dZo2mkiWRGlQBiu4bgOxI64ODS14l8HrXUPGXj7UvHmpCSKBC0dsoY7SxG0KPUIvXjkkHqDXteaAHtyRTguQahY8inBuKAHpw1Tsflqsh5qVj8tAEbfeqFLuL7Utt5yfaCpfyt437c4LbeuMnGamHU14X8WtNv/A3jWz8d6IxMVxMFuY8/Lvxgqf8AZdQfoRn0wAeweKfE+leFLCO+126NpbySiFXEbPl8FgMKCeimr+n3sWpWFvfWj7re5iWaJsEZVgCpweRkHvXkf7QupQ6z8LdF1C1DCG5voZlVxhlBglOCPUVtar4wHg34KaLeQAG9uNNtre1GMgOYR8x9gAT7nA70Aej206TfNDIjoCVypBGQcEcdweDVstXlnwC8L3Og+FpNT1DzVvNXdZyjk/LGB8uQf4jksT1wQDyK9O+9QAkjgmkjkApkqYNMCe9AEkzA4xQrECou9SgcUASI9Obpmo4xTnzigCBn+bFPHSmMuDmng8UAEYyaewxTYutPegB8BqwKrw1MKAH0tIKWgAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKA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UvhTTZtI0C1sLpo3liDbmjJK8sT3APetaigDD8LaNcaTLqbXLRsLy7edNhJwp6ZyBzSW2jXMPjG71d3ia3nt1hVQTvUgr1GMY49a3aKAOAFhd3XjzW5dOuRb3cCxFCw3I4KDKsPQ/pWj/YWtaxqVvL4lurX7LbP5iW9oGw7DoWz/APX9OM10FtpVpa6ldahChF1dBRI+SQcDA46Cr4z3oAwfFWiT6qLO4sJxb3tjL5kTOuVPTIP5CsrVdD8S67pstvqV3YwgAbIrcMFkYEcsSCcDkgAdcV2dFAHM+INAu9R8LWulwPCs8HlZZyQp2rg4IBP6V0U67onX1UgflUlFAGL4O0qfRdBhsLt4nljZiTExK4Jz3AP6VzWraaL34ix2lu3+jyLHd3sfbcmQufrx+ea7q6gS5t5YJc7JUKNg4OCMGqOjaDp+jK4sIdjSHLuzFmb6k0AaQGKWiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKAEoNFITQBFdSiGAv3PArKGWJJ71JdTefLx9wdKjWgCRBUiCmKKlWgByinqKatPFAElFFFADWphFSGmGgCNhTGFSEUxqAIWFMYVKw5pjCgCEj5qiI61MRzTCKAICOeabt5qcgN161GykHnpVxZDRGUppSpqMVqmjMg8ujy6nxRiqEQbPajZ7Cp9tG2mBXKe1JsqyUpNlZlkASnhelSbaULQDBV5qQDmgLTgKogKeKbinCmIKKKKYInj6ir8P3RWfH1FaEP3RWczWJMtOFNWnCsWaCGkNKaaTSASkJ5oJpuaYx9JSZpM0CFyKM03NGaBj6XNNzQTQIcKcKYKXNAAetNJoJ5ppPFAD807NRZp+aAFNNNOJ4phNACqaXNNBozQMetONNWnGkIWiiigAooooAKKKKAFooooASiiigBaKKKACiiigBKKKKAFooooASiiigBaKKKAEooooAWiiigBKKKKACiiigAooooAWijFGKAEooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACii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"
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
