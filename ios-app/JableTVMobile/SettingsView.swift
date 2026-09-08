import SwiftUI
import SwiftData
import UIKit

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

                Section("授权中心") {
                    NavigationLink {
                        LicenseAdminConsoleView()
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("授权控制台")
                                Text("连接 8789 发码、吊销、查看设备在线")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        } icon: {
                            Image(systemName: "key.horizontal.fill")
                                .foregroundStyle(.blue)
                        }
                    }

                    NavigationLink {
                        LicenseCenterView()
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("当前设备授权")
                                Text("\(viewModel.serverURL.isEmpty ? "请先连接服务" : viewModel.serverURL) · \(licenseStatusText)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        } icon: {
                            Image(systemName: "checkmark.seal.fill")
                                .foregroundStyle((viewModel.license?.activated ?? false) ? .green : .blue)
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

private struct LicenseAdminConsoleView: View {
    @AppStorage("licenseConsoleURL") private var consoleURL = "http://192.168.2.50:8789"
    @AppStorage("licenseConsolePassword") private var consolePassword = ""
    @State private var summary: LicenseAdminSummary?
    @State private var deviceID = ""
    @State private var owner = ""
    @State private var days = 365
    @State private var issuedCode = ""
    @State private var isLoading = false
    @State private var message = ""
    @State private var showMessage = false
    @FocusState private var focused: Bool

    var body: some View {
        Form {
            Section("控制台连接") {
                TextField("http://192.168.2.50:8789", text: $consoleURL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focused)

                SecureField("授权控制台密码", text: $consolePassword)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                Button {
                    Task { await refresh() }
                } label: {
                    if isLoading {
                        ProgressView()
                    } else {
                        Label("连接并刷新", systemImage: "arrow.clockwise")
                    }
                }
                .disabled(isLoading || consoleURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || consolePassword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            if let summary {
                Section("概览") {
                    LabeledContent("授权记录", value: "\(summary.recordCount)")
                    LabeledContent("在线设备", value: "\(summary.onlineCount)")
                    LabeledContent("吊销设备", value: "\(summary.revokedCount)")
                    if let revocationURL = summary.revocationURL, !revocationURL.isEmpty {
                        LabeledContent("吊销列表") {
                            Text(revocationURL)
                                .lineLimit(1)
                                .textSelection(.enabled)
                        }
                    }
                }
            }

            Section("签发授权码") {
                TextField("设备码", text: $deviceID, axis: .vertical)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("所属人备注", text: $owner)
                Stepper(days == 0 ? "有效期：永久" : "有效期：\(days) 天", value: $days, in: 0 ... 3650, step: 30)

                Button {
                    Task { await issue() }
                } label: {
                    Label("生成授权码", systemImage: "plus.seal")
                }
                .buttonStyle(.borderedProminent)
                .disabled(isLoading || deviceID.trimmingCharacters(in: .whitespacesAndNewlines).count < 8 || consolePassword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                if !issuedCode.isEmpty {
                    Text(issuedCode)
                        .font(.footnote.monospaced())
                        .textSelection(.enabled)

                    Button {
                        UIPasteboard.general.string = issuedCode
                        notify("授权码已复制")
                    } label: {
                        Label("复制授权码", systemImage: "doc.on.doc")
                    }
                }
            }

            Section("授权记录") {
                if let records = summary?.records, !records.isEmpty {
                    ForEach(records) { record in
                        recordRow(record)
                    }
                } else {
                    ContentUnavailableView("暂无授权记录", systemImage: "person.badge.key", description: Text("连接控制台后会显示已签发和已上报心跳的设备。"))
                }
            }

            if let revoked = summary?.revoked, !revoked.isEmpty {
                Section("吊销名单") {
                    ForEach(revoked, id: \.self) { device in
                        HStack(spacing: 10) {
                            Text(device)
                                .font(.footnote.monospaced())
                                .lineLimit(2)
                                .textSelection(.enabled)
                            Spacer()
                            Button("解除") {
                                Task { await unrevoke(deviceID: device) }
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }
            }
        }
        .navigationTitle("授权控制台")
        .navigationBarTitleDisplayMode(.inline)
        .scrollContentBackground(.hidden)
        .background(LinearGradient(colors: [Color(.systemGroupedBackground), Color.blue.opacity(0.10), Color.cyan.opacity(0.06)], startPoint: .topLeading, endPoint: .bottomTrailing))
        .alert("授权控制台", isPresented: $showMessage) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text(message)
        }
        .task {
            if !consoleURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               !consolePassword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                await refresh()
            }
        }
    }

    private func recordRow(_ record: LicenseAdminRecord) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(record.owner.isEmpty ? "未备注" : record.owner)
                        .font(.headline)
                    Text(record.deviceID)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    Text(recordDetail(record))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 6) {
                    Text(record.revoked ? "已吊销" : "正常")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(record.revoked ? .red : .green)
                    Text(record.online ? "在线" : "离线")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(record.online ? .blue : .secondary)
                }
            }

            HStack {
                if !record.code.isEmpty {
                    Button("复制授权码") {
                        UIPasteboard.general.string = record.code
                        notify("授权码已复制")
                    }
                    .buttonStyle(.bordered)
                }

                Button(record.revoked ? "解除吊销" : "立即吊销") {
                    Task {
                        if record.revoked {
                            await unrevoke(deviceID: record.deviceID)
                        } else {
                            await revoke(deviceID: record.deviceID)
                        }
                    }
                }
                .buttonStyle(.bordered)
                .tint(record.revoked ? .blue : .red)

                Button("删除") {
                    Task { await deleteRecord(deviceID: record.deviceID) }
                }
                .buttonStyle(.bordered)
                .tint(.secondary)
            }
            .font(.caption)
        }
        .padding(.vertical, 6)
    }

    private var client: LicenseConsoleClient {
        LicenseConsoleClient(baseURL: consoleURL, password: consolePassword)
    }

    private func refresh() async {
        await run {
            summary = try await client.summary()
            issuedCode = summary?.issued ?? issuedCode
        }
    }

    private func issue() async {
        let trimmedDeviceID = deviceID.trimmingCharacters(in: .whitespacesAndNewlines)
        await run {
            let result = try await client.issue(deviceID: trimmedDeviceID, owner: owner, days: days)
            summary = result
            issuedCode = result.issued ?? ""
            if !issuedCode.isEmpty {
                UIPasteboard.general.string = issuedCode
            }
        }
        if !issuedCode.isEmpty {
            notify("授权码已生成并复制")
        }
    }

    private func revoke(deviceID: String) async {
        await run {
            summary = try await client.revoke(deviceID: deviceID)
        }
    }

    private func unrevoke(deviceID: String) async {
        await run {
            summary = try await client.unrevoke(deviceID: deviceID)
        }
    }

    private func deleteRecord(deviceID: String) async {
        await run {
            summary = try await client.deleteRecord(deviceID: deviceID)
        }
    }

    private func run(_ operation: () async throws -> Void) async {
        focused = false
        isLoading = true
        defer { isLoading = false }
        do {
            try await operation()
        } catch {
            notify(error.localizedDescription)
        }
    }

    private func notify(_ text: String) {
        message = text
        showMessage = true
    }

    private func recordDetail(_ record: LicenseAdminRecord) -> String {
        var parts: [String] = []
        parts.append(record.expiresAt == 0 ? "永久有效" : "到期 \(dateText(record.expiresAt))")
        if let lastSeen = record.lastSeen, lastSeen > 0 {
            parts.append("最近上线 \(dateText(lastSeen))")
        } else {
            parts.append("从未上线")
        }
        if !record.hostname.isEmpty {
            parts.append(record.hostname)
        }
        if !record.lastIP.isEmpty {
            parts.append(record.lastIP)
        }
        return parts.joined(separator: " · ")
    }

    private func dateText(_ timestamp: Double?) -> String {
        guard let timestamp, timestamp > 0 else { return "-" }
        let date = Date(timeIntervalSince1970: timestamp)
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}

private struct LicenseCenterView: View {
    @EnvironmentObject private var viewModel: AppViewModel
    @State private var licenseCode = ""

    var body: some View {
        Form {
            Section("当前服务") {
                LabeledContent("服务地址", value: viewModel.serverURL.isEmpty ? "-" : viewModel.serverURL)
                LabeledContent("访问密码") {
                    Text(viewModel.accessPassword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "未填写" : "已填写")
                        .foregroundStyle(viewModel.accessPassword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Color.secondary : Color.green)
                }
            }

            Section("授权信息") {
                LabeledContent("授权状态") {
                    Text(licenseStatusText)
                        .foregroundStyle((viewModel.license?.activated ?? false) ? .green : .red)
                }
                if let deviceID = viewModel.license?.deviceID, !deviceID.isEmpty {
                    LabeledContent("设备码", value: deviceID)
                        .textSelection(.enabled)
                }
                LabeledContent("有效期", value: licenseExpiryText)
                if let message = viewModel.license?.message, !message.isEmpty {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section("激活授权") {
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
            }
        }
        .navigationTitle("授权中心")
        .navigationBarTitleDisplayMode(.inline)
        .scrollContentBackground(.hidden)
        .background(LinearGradient(colors: [Color(.systemGroupedBackground), Color.blue.opacity(0.10), Color.cyan.opacity(0.06)], startPoint: .topLeading, endPoint: .bottomTrailing))
        .task {
            await viewModel.refreshLicense()
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
}
