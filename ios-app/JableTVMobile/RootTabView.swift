import SwiftUI
import SwiftData
import AVKit
import AVFoundation

struct RootTabView: View {
    @EnvironmentObject private var viewModel: AppViewModel
    @Environment(\.modelContext) private var modelContext
    @Query private var configurations: [ServerConfiguration]
    @Query private var catalogCaches: [CatalogPageCache]
    @State private var connectionInput = "http://192.168.2.50:8788"
    @State private var accessPasswordInput = ""
    @State private var isTestingConnection = false
    @State private var connectionAlert: String?

    var body: some View {
        Group {
            if viewModel.isConnected {
                TabView(selection: $viewModel.selectedTab) {
                    CatalogView()
                        .tabItem {
                            Label("影片", systemImage: "square.grid.2x2.fill")
                        }
                        .tag(0)

                    MediaLibraryView()
                        .tabItem {
                            Label("媒体库", systemImage: "play.rectangle.fill")
                        }
                        .tag(1)

                    HuangguoView()
                        .tabItem {
                            Label("黄果", systemImage: "bolt.fill")
                        }
                        .tag(2)

                    TasksView()
                        .tabItem {
                            Label("下载", systemImage: "arrow.down.circle.fill")
                        }
                        .tag(3)

                    SettingsView(onDisconnect: disconnect)
                        .tabItem {
                            Label("设置", systemImage: "slider.horizontal.3")
                        }
                        .tag(4)
                }
                .tint(.blue)
                .toolbarBackground(.visible, for: .tabBar)
            } else {
                NavigationStack {
                    connectionConsole
                    .navigationTitle("")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbarBackground(.visible, for: .navigationBar)
                }
            }
        }
        .tint(.blue)
        .alert("连接失败", isPresented: Binding(
            get: { connectionAlert != nil },
            set: { if !$0 { connectionAlert = nil } }
        )) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text(connectionAlert ?? "")
        }
        .fullScreenCover(item: Binding(
            get: { viewModel.playingURL.map { PlayRequest(id: $0.absoluteString, title: viewModel.playingTitle, url: $0) } },
            set: { value in
                if value == nil {
                    viewModel.playingURL = nil
                }
            }
        )) { request in
            PlaybackView(request: request) {
                viewModel.playingURL = nil
            }
        }
        .task {
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
            try? AVAudioSession.sharedInstance().setActive(true)
            if let saved = savedConfigurations.first, !saved.serverURL.isEmpty {
                connectionInput = saved.serverURL
                accessPasswordInput = saved.accessPassword ?? ""
                viewModel.statusMessage = "请选择服务器并点击连接"
            }
        }
    }

    private var connectionConsole: some View {
        ZStack {
            LinearGradient(
                colors: [Color(.systemGroupedBackground), Color.blue.opacity(0.08), Color.cyan.opacity(0.06)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 34) {
                        HStack(spacing: 24) {
                            Image("BrandLogo")
                                .resizable()
                                .scaledToFit()
                                .frame(width: 96, height: 96)
                                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                                .shadow(color: .blue.opacity(0.18), radius: 18, x: 0, y: 10)

                            VStack(alignment: .leading, spacing: 8) {
                                Text("MEDIA CONSOLE")
                                    .font(.callout.weight(.heavy))
                                    .tracking(1.6)
                                    .foregroundStyle(.blue)
                                Text("连接媒体库")
                                    .font(.largeTitle.bold())
                                    .foregroundStyle(.primary)
                                Text("家庭影音中心")
                                    .font(.title3.weight(.medium))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.top, 54)

                        Capsule()
                            .fill(Color.blue)
                            .frame(width: 74, height: 7)

                        VStack(alignment: .leading, spacing: 10) {
                            Label("连接信息", systemImage: "server.rack")
                                .font(.title3.bold())
                                .foregroundStyle(.primary)
                            Text("jable-media-library 管理端")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }

                        VStack(alignment: .leading, spacing: 20) {
                            consoleField(
                                title: "服务地址",
                                systemImage: "link",
                                placeholder: "http://192.168.2.50:8788",
                                text: $connectionInput,
                                isSecure: false
                            )

                            consoleField(
                                title: "访问密码（可选）",
                                systemImage: "lock",
                                placeholder: "未设置可留空",
                                text: $accessPasswordInput,
                                isSecure: true
                            )
                        }
                        .padding(22)
                        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 28, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 28, style: .continuous)
                                .stroke(Color(.separator).opacity(0.55), lineWidth: 1)
                        )

                        if !savedConfigurations.isEmpty {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("最近连接")
                                    .font(.headline)
                                ForEach(savedConfigurations.prefix(3)) { config in
                                    Button {
                                        connectionInput = config.serverURL
                                        accessPasswordInput = config.accessPassword ?? ""
                                        Task { await connect() }
                                    } label: {
                                        HStack {
                                            Image(systemName: "clock.arrow.circlepath")
                                                .foregroundStyle(.blue)
                                            Text(config.serverURL)
                                                .font(.subheadline.weight(.semibold))
                                                .foregroundStyle(.primary)
                                                .lineLimit(1)
                                            Spacer()
                                            Image(systemName: "chevron.right")
                                                .font(.caption.bold())
                                                .foregroundStyle(.secondary)
                                        }
                                        .padding(14)
                                        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }

                        if !viewModel.statusMessage.isEmpty {
                            Text(viewModel.statusMessage)
                                .font(.callout.weight(.semibold))
                                .foregroundStyle(isTestingConnection ? .blue : .secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(14)
                                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        }

                        Text("版本 \(appVersion)（网络兼容版）")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                    .padding(.horizontal, 28)
                    .padding(.bottom, 120)
                }

                Button {
                    Task { await connect() }
                } label: {
                    HStack(spacing: 10) {
                        if isTestingConnection {
                            ProgressView()
                                .tint(.white)
                        } else {
                            Image(systemName: "arrow.right")
                                .font(.title3.weight(.bold))
                            Text("连接")
                                .font(.headline.bold())
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 58)
                    .background(Color.blue, in: Capsule())
                    .foregroundStyle(.white)
                    .shadow(color: .blue.opacity(0.25), radius: 18, x: 0, y: 10)
                }
                .disabled(connectionInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isTestingConnection)
                .opacity(connectionInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.45 : 1)
                .padding(.horizontal, 28)
                .padding(.bottom, 20)
                .background(.regularMaterial)
            }
        }
    }

    private func consoleField(title: String, systemImage: String, placeholder: String, text: Binding<String>, isSecure: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label {
                Text(title)
                    .font(.headline)
            } icon: {
                Image(systemName: systemImage)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(Color.blue, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }

            Group {
                if isSecure {
                    SecureField(placeholder, text: text)
                } else {
                    TextField(placeholder, text: text)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                }
            }
            .autocorrectionDisabled()
            .font(.title3)
            .padding(.horizontal, 16)
            .frame(height: 58)
            .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(Color(.separator).opacity(0.35), lineWidth: 1)
            )
        }
    }

    private var savedConfigurations: [ServerConfiguration] {
        configurations.sorted { lhs, rhs in
            (lhs.lastConnectedAt ?? .distantPast) > (rhs.lastConnectedAt ?? .distantPast)
        }
    }

    private var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "-"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "-"
        return "\(version) (\(build))"
    }

    private func connect() async {
        isTestingConnection = true
        defer { isTestingConnection = false }
        let normalized = viewModel.normalized(connectionInput)
        let password = accessPasswordInput.trimmingCharacters(in: .whitespacesAndNewlines)
        viewModel.configure(serverURL: normalized, accessPassword: password)
        guard await viewModel.verifyConnection() else {
            connectionAlert = viewModel.statusMessage
            return
        }
        if let saved = configurations.first(where: { $0.serverURL == normalized }) {
            saved.serverURL = normalized
            saved.accessPassword = password
            saved.lastConnectedAt = Date()
        } else {
            modelContext.insert(ServerConfiguration(serverURL: normalized, accessPassword: password, lastConnectedAt: Date()))
        }
        try? modelContext.save()
        if let cache = cache(for: normalized, page: 1) {
            viewModel.applyCachedCatalog(cache)
        }
        await viewModel.refreshAll(refreshCatalog: viewModel.catalogItems.isEmpty)
        saveCatalogCache()
    }

    private func disconnect() {
        viewModel.serverURL = ""
        viewModel.isConnected = false
        viewModel.health = nil
        viewModel.catalogItems = []
        connectionInput = ""
        accessPasswordInput = ""
    }

    private func cache(for serverURL: String, page: Int) -> CatalogPageCache? {
        let normalized = viewModel.normalized(serverURL)
        return catalogCaches
            .filter { $0.serverURL == normalized && $0.page == page }
            .sorted { $0.updatedAt > $1.updatedAt }
            .first
    }

    private func saveCatalogCache() {
        guard viewModel.isConfigured, let payload = viewModel.catalogCachePayload(), !viewModel.catalogItems.isEmpty else { return }
        let normalized = viewModel.normalized(viewModel.serverURL)
        if let existing = cache(for: normalized, page: viewModel.catalogPage) {
            existing.payload = payload
            existing.hasNext = viewModel.catalogHasNext
            existing.pageSize = viewModel.catalogPageSize
            existing.updatedAt = Date()
        } else {
            modelContext.insert(CatalogPageCache(
                serverURL: normalized,
                page: viewModel.catalogPage,
                payload: payload,
                hasNext: viewModel.catalogHasNext,
                pageSize: viewModel.catalogPageSize
            ))
        }
        try? modelContext.save()
    }
}

private struct PlayRequest: Identifiable {
    let id: String
    let title: String
    let url: URL
}

private struct PlaybackView: View {
    let request: PlayRequest
    let close: () -> Void
    @State private var player: AVPlayer?
    @State private var isReady = false

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                if let player {
                    VideoPlayer(player: player)
                        .ignoresSafeArea(edges: .bottom)
                } else {
                        ProgressView("正在准备播放…")
                        .tint(.blue)
                }

                if !isReady {
                    VStack {
                        Spacer()
                        HStack {
                            ProgressView()
                                .tint(.blue)
                            Text("正在加载视频流")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(.black.opacity(0.72), in: Capsule())
                        .padding(.bottom, 28)
                    }
                }
            }
            .navigationTitle(request.title.isEmpty ? "正在播放" : request.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color.black, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        restart()
                    } label: {
                        Label("重新加载", systemImage: "arrow.clockwise")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        player?.pause()
                        close()
                    } label: {
                        Label("关闭", systemImage: "xmark")
                    }
                }
            }
            .onAppear {
                restart()
            }
            .onDisappear {
                player?.pause()
                player = nil
            }
        }
    }

    private func restart() {
        isReady = false
        let next = AVPlayer(url: request.url)
        player = next
        next.play()
        Task {
            try? await Task.sleep(for: .seconds(1))
            isReady = true
        }
    }
}
