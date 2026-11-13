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
    @Environment(\.openLogin) private var openLogin
    @StateObject private var syncStore = ListeningSyncStore.shared
    @StateObject private var moumusicServer = MoumusicServerStore.shared
    @State private var showDownloads = false
    @State private var showMoumusicAdminLogin = false
    @State private var showMoumusicAdminUsers = false
    @State private var showQQMusicLogin = false
    @State private var showKugouLogin = false
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
                        ForEach(LXCatalogPlatform.catalogueCases.filter { $0 != .aggregate }) { platform in
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
                PlatformAccountPlaylists(platform: .kg)
                    .padding(.horizontal, -16)
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
                PlatformAccountPlaylists(platform: .tx)
                    .padding(.horizontal, -16)
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
                            Text(account.isLoggedIn ? (account.vipLabel ?? "非会员") : "登录后同步歌单和收藏")
                                .font(.caption)
                                .foregroundStyle(.secondary)
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
                    ) + [
                        ProfileStat(title: "专辑", value: "\(account.likedAlbums.count)"),
                        ProfileStat(title: "歌手", value: "\(account.likedArtists.count)")
                    ])
                }
            }
            if account.isLoggedIn {
                let favorites = account.userPlaylists.filter(\.isLikedSongsList)
                playlistGroup("我喜欢的音乐", favorites)
                playlistGroup("收藏的歌单", Array(account.subscribedPlaylists.prefix(8)))
                playlistGroup("我创建的歌单", Array(account.createdPlaylists.prefix(8)))
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
                    Text(loggedIn ? (name ?? title) : "未登录\(title)")
                        .font(.headline)
                        .lineLimit(1)
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
                            if bilibili.isLoggedIn, bilibili.level > 0 {
                                Text("Lv.\(bilibili.level)")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(Theme.accent)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Theme.accent.opacity(0.14), in: Capsule())
                            }
                        }
                        Text(bilibili.isLoggedIn ? (bilibili.membershipTitle ?? "非会员") : "登录后同步账号资料")
                            .font(.caption)
                            .foregroundStyle(.secondary)
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

    private func playlistGroup(_ title: String, _ playlists: [PlaylistSummary]) -> some View {
        if !playlists.isEmpty {
            Text(title)
                .font(.headline.weight(.semibold))
                .padding(.horizontal, 4)
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
        }
    }

    private func profileTile(_ title: String, icon: String, tint: Color, destination: Destination) -> some View {
        NavigationLink(value: destination) {
            profileTileLabel(title, icon: icon, tint: tint)
        }
        .buttonStyle(.plain)
    }

    private func profileTileLabel(_ title: String, icon: String, tint: Color) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(tint)
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

private struct ListeningReportView: View {
    @ObservedObject private var stats = ListeningStatsStore.shared

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

                HStack(spacing: 0) {
                    reportMetric("播放", "\(stats.totalPlayCount)")
                    reportDivider
                    reportMetric("连续", "\(stats.streakDays) 天")
                    reportDivider
                    reportMetric("今日", minutesText(todayMinutes))
                }
                .padding(.vertical, 8)

                Divider().padding(.horizontal, 16)

                HStack(spacing: 0) {
                    reportMetric("近 7 天", minutesText(weekMinutes))
                    reportDivider
                    reportMetric("日均", minutesText(averageMinutes))
                    reportDivider
                    reportMetric("歌曲", "\(stats.records.count)")
                }
                .padding(.vertical, 8)

                VStack(alignment: .leading, spacing: 14) {
                    Text("近 7 天")
                        .font(.headline.weight(.semibold))
                    HStack(alignment: .bottom, spacing: 8) {
                        ForEach(Array(week.enumerated()), id: \.offset) { _, day in
                            VStack(spacing: 6) {
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .fill(Theme.accent.opacity(day.minutes > 0 ? 1 : 0.18))
                                    .frame(height: barHeight(day.minutes))
                                Text(day.label)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }
                    .frame(height: 120, alignment: .bottom)
                }
                .padding(16)
            }
        }
        .navigationTitle("听歌报告")
        .navigationBarTitleDisplayMode(.inline)
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

    private var week: [(label: String, minutes: Double)] { stats.lastSevenDays() }
    private var weekMinutes: Double { week.reduce(0) { $0 + $1.minutes } }
    private var todayMinutes: Double { week.last?.minutes ?? 0 }
    private var averageMinutes: Double { week.isEmpty ? 0 : weekMinutes / Double(week.count) }

    private func barHeight(_ minutes: Double) -> CGFloat {
        let peak = max(week.map(\.minutes).max() ?? 0, 1)
        return max(4, CGFloat(minutes / peak) * 86)
    }

    private func minutesText(_ minutes: Double) -> String {
        let total = Int(minutes.rounded())
        if total >= 60 { return "\(total / 60)小时\(total % 60)分" }
        return "\(total)分钟"
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
