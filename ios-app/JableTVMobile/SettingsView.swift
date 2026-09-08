import SwiftUI
import SwiftData

struct SettingsView: View {
    @EnvironmentObject private var viewModel: AppViewModel
    @Environment(\.modelContext) private var modelContext
    @Query private var configurations: [ServerConfiguration]
    let onDisconnect: () -> Void
    @FocusState private var focused: Bool
    @State private var licenseCode = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("服务地址") {
                    TextField("http://192.168.2.71:8788", text: $viewModel.serverURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focused)

                    SecureField("访问密码（可选）", text: $viewModel.accessPassword)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    Button {
                        focused = false
                        viewModel.configure(serverURL: viewModel.serverURL, accessPassword: viewModel.accessPassword)
                        Task {
                            _ = await viewModel.verifyConnection()
                            await viewModel.refreshSettings()
                            await viewModel.refreshTasks()
                            saveCurrentServer()
                        }
                    } label: {
                        Label("测试连接", systemImage: "network")
                    }

                    Button {
                        saveCurrentServer()
                    } label: {
                        Label("保存当前服务器", systemImage: "plus.circle")
                    }
                }

                if !savedConfigurations.isEmpty {
                    Section("已保存服务器") {
                        ForEach(savedConfigurations) { config in
                            HStack {
                                Button {
                                    switchServer(config)
                                } label: {
                                    Label(config.serverURL, systemImage: config.serverURL == viewModel.serverURL ? "checkmark.circle.fill" : "server.rack")
                                        .lineLimit(1)
                                }
                                Spacer()
                                Button(role: .destructive) {
                                    modelContext.delete(config)
                                    try? modelContext.save()
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                    }
                }

                Section("连接状态") {
                    LabeledContent("当前状态", value: viewModel.health?.status ?? "未连接")
                    LabeledContent("架构", value: viewModel.health?.architecture ?? "-")
                    LabeledContent("浏览器自动化", value: (viewModel.health?.browser ?? false) ? "可用" : "不可用")
                    LabeledContent("下载器", value: (viewModel.health?.downloader ?? false) ? "可用" : "不可用")
                    LabeledContent("媒体目录", value: viewModel.health?.media ?? "-")
                }

                Section("授权中心") {
                    LabeledContent("授权状态") {
                        Text(licenseStatusText)
                            .foregroundStyle((viewModel.license?.activated ?? false) ? .green : .red)
                    }
                    if let deviceID = viewModel.license?.deviceID, !deviceID.isEmpty {
                        LabeledContent("设备码", value: deviceID)
                            .textSelection(.enabled)
                    }
                    LabeledContent("有效期", value: licenseExpiryText)

                    TextField("粘贴授权码", text: $licenseCode, axis: .vertical)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    HStack {
                        Button {
                            Task { await viewModel.refreshLicense() }
                        } label: {
                            Label("刷新授权", systemImage: "arrow.clockwise")
                        }

                        Spacer()

                        Button {
                            let code = licenseCode.trimmingCharacters(in: .whitespacesAndNewlines)
                            Task {
                                await viewModel.activateLicense(code)
                                licenseCode = ""
                            }
                        } label: {
                            Label("激活", systemImage: "checkmark.seal")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(licenseCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }

                    if let message = viewModel.license?.message, !message.isEmpty {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("下载设置") {
                    Stepper("默认线程 \(viewModel.manualThreads)", value: $viewModel.manualThreads, in: 1 ... 32)
                    Toggle("下载后整理", isOn: $viewModel.organizeEnabled)
                    Toggle("允许重复下载", isOn: $viewModel.allowDuplicate)
                    Toggle("刮削失败发送到失败路径", isOn: boolBinding(\.failureRouteEnabled, defaultValue: false))
                    TextField("失败路径", text: stringBinding(\.failurePath))
                }

                Section("网络与站点") {
                    TextField("代理地址", text: stringBinding(\.proxy))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                    Toggle("隐私模式", isOn: boolBinding(\.privacyMode, defaultValue: true))

                    TextField("Jable Cookie", text: stringBinding(\.jableCookie), axis: .vertical)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                    TextField("服务访问地址", text: stringBinding(\.serviceBaseURL))
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                }

                Section("115 登录与播放") {
                    Picker("登录模式", selection: stringBinding(\.cloud115Mode, defaultValue: "bridge")) {
                        Text("中转").tag("bridge")
                        Text("Cookie").tag("cookie")
                    }

                    Picker("播放方式", selection: stringBinding(\.cloud115PlayMode, defaultValue: "proxy")) {
                        Text("后端代理").tag("proxy")
                        Text("302 直连").tag("redirect")
                    }

                    TextField("115 中转地址", text: stringBinding(\.cloud115Endpoint))
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                    TextField("115 Token", text: stringBinding(\.cloud115Token))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    TextField("115 Cookie", text: stringBinding(\.cloud115Cookie), axis: .vertical)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                    Button {
                        Task { await viewModel.check115Login() }
                    } label: {
                        if viewModel.isChecking115Login {
                            ProgressView()
                        } else {
                            Label("检测 115 登录状态", systemImage: "checkmark.shield")
                        }
                    }

                    if !viewModel.check115Message.isEmpty {
                        Label(
                            viewModel.check115Message,
                            systemImage: viewModel.check115OK == true ? "checkmark.circle.fill" : "xmark.circle.fill"
                        )
                        .foregroundStyle(viewModel.check115OK == true ? .green : .red)
                    }
                }

                Section("管线 A · 本地下载") {
                    Toggle("刮削总开关", isOn: boolBinding(\.localScrapeEnabled, defaultValue: true))
                    Toggle("刮削后转移", isOn: boolBinding(\.localTransferEnabled, defaultValue: true))
                    TextField("转移路径（留空使用默认 /media）", text: stringBinding(\.localTransferPath))
                }

                Section("管线 B · 手动刮削与监控") {
                    Toggle("手动刮削总开关", isOn: boolBinding(\.manualScrapeEnabled, defaultValue: true))
                    Toggle("手动刮削后转移", isOn: boolBinding(\.manualTransferEnabled, defaultValue: true))
                    TextField("手动转移路径", text: stringBinding(\.manualTransferPath))
                    Toggle("Watch Folder 监控", isOn: boolBinding(\.watchEnabled, defaultValue: false))
                    TextField("监控目录", text: stringBinding(\.watchDir))
                    Stepper("扫描间隔 \(viewModel.settings.watchInterval ?? 10) 秒", value: intBinding(\.watchInterval, defaultValue: 10), in: 3 ... 300)
                }

                Section("管线 C/D · 115 转移与 STRM") {
                    Toggle("离线直接下载到目标目录", isOn: boolBinding(\.cloudTransferEnabled, defaultValue: false))
                    TextField("115 目标目录 CID", text: stringBinding(\.cloudTransferCid))
                    TextField("115 目标路径", text: stringBinding(\.cloudTransferPath))
                    Stepper("轮询间隔 \(viewModel.settings.cloudPollInterval ?? 300) 秒", value: intBinding(\.cloudPollInterval, defaultValue: 300), in: 10 ... 600)
                    Stepper("广告过滤 \(viewModel.settings.cloudAdMinMB ?? 0, specifier: "%.0f") MB", value: doubleBinding(\.cloudAdMinMB, defaultValue: 0), in: 0 ... 500, step: 1)
                    Toggle("离线完成后生成 STRM 并刮削", isOn: boolBinding(\.autoStrmEnabled, defaultValue: false))
                    TextField("STRM 根目录", text: stringBinding(\.strmRootDir, defaultValue: "strm"))
                }

                Section("自动离线") {
                    Toggle("自动离线总开关", isOn: boolBinding(\.autoOfflineEnabled, defaultValue: false))
                    Toggle("浏览详情触发", isOn: boolBinding(\.autoOfflineBrowse, defaultValue: true))
                    Toggle("定时追新扫描", isOn: boolBinding(\.autoOfflineSchedule, defaultValue: true))
                    Stepper("检查间隔 \(viewModel.settings.autoOfflineInterval ?? 6) 小时", value: intBinding(\.autoOfflineInterval, defaultValue: 6), in: 1 ... 72)
                    Stepper("扫描页数 \(viewModel.settings.autoOfflinePages ?? 2)", value: intBinding(\.autoOfflinePages, defaultValue: 2), in: 1 ... 10)
                    TextField("番号白名单（逗号分隔）", text: stringBinding(\.autoOfflineWhitelist))
                    Stepper("最短时长 \(viewModel.settings.autoOfflineMinDuration ?? 60) 分钟", value: intBinding(\.autoOfflineMinDuration, defaultValue: 60), in: 0 ... 600)
                    Stepper("最小体积 \(viewModel.settings.autoOfflineMinSize ?? 3, specifier: "%.0f") GB", value: doubleBinding(\.autoOfflineMinSize, defaultValue: 3), in: 0 ... 200, step: 1)
                    Stepper("每日上限 \(viewModel.settings.autoOfflineDailyLimit ?? 5) 部", value: intBinding(\.autoOfflineDailyLimit, defaultValue: 5), in: 1 ... 50)
                }

                Section("黄果短剧") {
                    Picker("上传策略", selection: stringBinding(\.hgUploadStrategy, defaultValue: "completed")) {
                        Text("完结后上传").tag("completed")
                        Text("每集完成上传").tag("episode")
                        Text("不上传").tag("never")
                    }
                    Toggle("上传后删除本地源文件", isOn: boolBinding(\.hgDeleteAfterUpload, defaultValue: false))
                    TextField("115 目标目录 CID", text: stringBinding(\.hgTargetCid))
                    TextField("115 目标路径", text: stringBinding(\.hgTargetPath, defaultValue: "/黄果短剧"))
                    Stepper("追更检查 \(viewModel.settings.hgCheckInterval ?? 6) 小时", value: intBinding(\.hgCheckInterval, defaultValue: 6), in: 1 ... 72)
                    Toggle("黄果下载使用代理", isOn: boolBinding(\.hgUseProxy, defaultValue: true))
                    TextField("备用镜像（逗号/空格分隔）", text: stringBinding(\.hgSiteMirrors))
                    Stepper("同剧并发 \(viewModel.settings.hgEpisodeConcurrency ?? 2)", value: intBinding(\.hgEpisodeConcurrency, defaultValue: 2), in: 1 ... 4)
                    Toggle("启用追更", isOn: boolBinding(\.hgFollowEnabled, defaultValue: true))
                    Stepper("每轮追更 \(viewModel.settings.hgFollowPages ?? 3) 部", value: intBinding(\.hgFollowPages, defaultValue: 3), in: 1 ... 20)
                }

                Section {
                    Button {
                        viewModel.settings.threads = viewModel.manualThreads
                        viewModel.settings.organizeEnabled = viewModel.organizeEnabled
                        viewModel.settings.allowDuplicate = viewModel.allowDuplicate
                        Task { await viewModel.saveSettings() }
                    } label: {
                        if viewModel.isSavingSettings {
                            ProgressView()
                                .frame(maxWidth: .infinity)
                        } else {
                            Label("保存服务设置", systemImage: "square.and.arrow.down")
                                .frame(maxWidth: .infinity)
                        }
                    }
                }

                Section {
                    Button(role: .destructive) {
                        onDisconnect()
                    } label: {
                        HStack {
                            Spacer()
                            Label("退出", systemImage: "rectangle.portrait.and.arrow.right")
                            Spacer()
                        }
                    }
                }
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .scrollContentBackground(.hidden)
            .background(LinearGradient(colors: [Color(.systemGroupedBackground), Color.blue.opacity(0.10), Color.cyan.opacity(0.06)], startPoint: .topLeading, endPoint: .bottomTrailing))
            .toolbarBackground(.visible, for: .navigationBar)
            .task {
                await viewModel.refreshSettings()
                await viewModel.refreshLicense()
            }
        }
    }

    private var licenseStatusText: String {
        guard let license = viewModel.license else { return "未读取" }
        return license.activated ? "已授权" : "未授权"
    }

    private var licenseExpiryText: String {
        guard let expiresAt = viewModel.license?.expiresAt else { return "-" }
        if expiresAt <= 0 { return "永久有效" }
        let date = Date(timeIntervalSince1970: expiresAt)
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    private func stringBinding(_ keyPath: WritableKeyPath<AppSettings, String?>, defaultValue: String = "") -> Binding<String> {
        Binding(
            get: { viewModel.settings[keyPath: keyPath] ?? defaultValue },
            set: { viewModel.settings[keyPath: keyPath] = $0 }
        )
    }

    private func boolBinding(_ keyPath: WritableKeyPath<AppSettings, Bool?>, defaultValue: Bool) -> Binding<Bool> {
        Binding(
            get: { viewModel.settings[keyPath: keyPath] ?? defaultValue },
            set: { viewModel.settings[keyPath: keyPath] = $0 }
        )
    }

    private func intBinding(_ keyPath: WritableKeyPath<AppSettings, Int?>, defaultValue: Int) -> Binding<Int> {
        Binding(
            get: { viewModel.settings[keyPath: keyPath] ?? defaultValue },
            set: { viewModel.settings[keyPath: keyPath] = $0 }
        )
    }

    private func doubleBinding(_ keyPath: WritableKeyPath<AppSettings, Double?>, defaultValue: Double) -> Binding<Double> {
        Binding(
            get: { viewModel.settings[keyPath: keyPath] ?? defaultValue },
            set: { viewModel.settings[keyPath: keyPath] = $0 }
        )
    }

    private var savedConfigurations: [ServerConfiguration] {
        configurations.sorted { lhs, rhs in
            (lhs.lastConnectedAt ?? .distantPast) > (rhs.lastConnectedAt ?? .distantPast)
        }
    }

    private func saveCurrentServer() {
        let normalized = viewModel.normalized(viewModel.serverURL)
        guard !normalized.isEmpty else { return }
        viewModel.serverURL = normalized
        let password = viewModel.accessPassword.trimmingCharacters(in: .whitespacesAndNewlines)
        if let existing = configurations.first(where: { $0.serverURL == normalized }) {
            existing.accessPassword = password
            existing.lastConnectedAt = Date()
        } else {
            modelContext.insert(ServerConfiguration(serverURL: normalized, accessPassword: password, lastConnectedAt: Date()))
        }
        try? modelContext.save()
    }

    private func switchServer(_ config: ServerConfiguration) {
        focused = false
        viewModel.configure(serverURL: config.serverURL, accessPassword: config.accessPassword ?? "")
        config.lastConnectedAt = Date()
        try? modelContext.save()
        Task {
            await viewModel.refreshAll(refreshCatalog: true)
        }
    }
}
