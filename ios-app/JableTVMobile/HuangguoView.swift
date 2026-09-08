import SwiftUI
import Kingfisher

struct HuangguoView: View {
    @EnvironmentObject private var viewModel: AppViewModel
    @State private var manualURL = ""
    @State private var selectedFilter = "catalog"
    @State private var runningID = ""

    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("黄果短剧")
                            .font(.title2.bold())
                        Text("浏览、在线播放、入库、下载、追更和上传 115")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        LinearGradient(colors: [.orange.opacity(0.24), .blue.opacity(0.12), Color(.secondarySystemGroupedBackground)], startPoint: .topLeading, endPoint: .bottomTrailing),
                        in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                    )

                    Picker("黄果", selection: $selectedFilter) {
                        Text("站点列表").tag("catalog")
                        Text("追剧库").tag("series")
                    }
                    .pickerStyle(.segmented)

                    if selectedFilter == "catalog" {
                        catalogSection
                    } else {
                        seriesSection
                    }

                    manualAddSection
                }
                .padding(16)
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $viewModel.huangguoSearchText, prompt: "搜索短剧名称")
            .onSubmit(of: .search) {
                Task { await viewModel.refreshHuangguoCatalog(page: 1, force: true) }
            }
            .scrollContentBackground(.hidden)
            .background(LinearGradient(colors: [Color(.systemGroupedBackground), Color.orange.opacity(0.08), Color.blue.opacity(0.06)], startPoint: .topLeading, endPoint: .bottomTrailing))
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task {
                            if selectedFilter == "catalog" {
                                await viewModel.refreshHuangguoCatalog(force: true)
                            } else {
                                await viewModel.refreshHuangguoSeries()
                            }
                        }
                    } label: {
                        Label("刷新", systemImage: "arrow.clockwise")
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                Text(viewModel.statusMessage)
                    .font(.footnote)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                    .padding(.vertical, 9)
                    .background(.regularMaterial)
            }
            .task {
                if viewModel.huangguoCatalogItems.isEmpty {
                    await viewModel.refreshHuangguoCatalog(force: false)
                }
                await viewModel.refreshHuangguoSeries()
            }
        }
    }

    private var catalogSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !viewModel.huangguoTabs.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(viewModel.huangguoTabs) { tab in
                            Button {
                                Task { await viewModel.refreshHuangguoCatalog(tab: tab.id, page: 1, force: false) }
                            } label: {
                                Text(tab.name)
                                    .font(.subheadline.weight(.semibold))
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 8)
                                    .background(viewModel.huangguoCatalogTab == tab.id ? Color.blue : Color(.secondarySystemGroupedBackground), in: Capsule())
                                    .foregroundStyle(viewModel.huangguoCatalogTab == tab.id ? .white : .primary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            HStack {
                Button("上一页") {
                    Task { await viewModel.refreshHuangguoCatalog(page: max(1, viewModel.huangguoCatalogPage - 1), force: false) }
                }
                .buttonStyle(.bordered)
                .disabled(viewModel.huangguoCatalogPage <= 1 || viewModel.isLoadingHuangguo)
                Spacer()
                Text("第 \(viewModel.huangguoCatalogPage) 页")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button("下一页") {
                    Task { await viewModel.refreshHuangguoCatalog(page: viewModel.huangguoCatalogPage + 1, force: false) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.isLoadingHuangguo || viewModel.huangguoCatalogItems.isEmpty)
            }

            if viewModel.isLoadingHuangguo && viewModel.huangguoCatalogItems.isEmpty {
                ProgressView("正在读取黄果列表…")
                    .frame(maxWidth: .infinity)
                    .padding(40)
            } else if viewModel.huangguoCatalogItems.isEmpty {
                ContentUnavailableView("没有解析到短剧列表", systemImage: "play.rectangle.on.rectangle", description: Text("请检查 Web 端代理和黄果镜像设置后刷新。"))
            } else {
                LazyVGrid(columns: columns, spacing: 14) {
                    ForEach(viewModel.huangguoCatalogItems) { item in
                        NavigationLink {
                            HuangguoCatalogDetailView(item: item)
                        } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                KFImage(viewModel.client().proxiedImageURL(item.coverURL))
                                    .placeholder {
                                        ZStack {
                                            RoundedRectangle(cornerRadius: 12).fill(Color(.secondarySystemFill))
                                            Image(systemName: "play.rectangle")
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    .resizable()
                                    .scaledToFill()
                                    .frame(maxWidth: .infinity)
                                    .aspectRatio(2.0 / 3.0, contentMode: .fill)
                                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                    .blur(radius: viewModel.isPrivacyModeEnabled ? 10 : 0)
                                Text(item.title)
                                    .font(.subheadline.bold())
                                    .foregroundStyle(.primary)
                                    .lineLimit(2)
                                Text(item.remark.isEmpty ? item.id : item.remark)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            .padding(10)
                            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var seriesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Button {
                    Task { await viewModel.runHuangguoAction(.retryFailedAll) }
                } label: {
                    actionPill("重试失败", systemImage: "arrow.clockwise", isPrimary: false)
                }
                .buttonStyle(.plain)
                Button {
                    Task { await viewModel.runHuangguoAction(.downloadMissingAll) }
                } label: {
                    actionPill("下载缺失", systemImage: "icloud.and.arrow.down", isPrimary: true)
                }
                .buttonStyle(.plain)
            }

            if viewModel.huangguoSeries.isEmpty {
                ContentUnavailableView("追剧库为空", systemImage: "books.vertical", description: Text("从站点列表或手动 URL 添加短剧后会显示在这里。"))
            } else {
                LazyVStack(spacing: 12) {
                    ForEach(viewModel.huangguoSeries) { item in
                        NavigationLink {
                            HuangguoSeriesDetailView(series: item)
                        } label: {
                            HStack(spacing: 12) {
                                KFImage(viewModel.client().huangguoCoverURL(seriesID: item.id))
                                    .placeholder {
                                        Image(systemName: "play.square.stack")
                                            .foregroundStyle(.secondary)
                                    }
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 82, height: 124)
                                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                    .blur(radius: viewModel.isPrivacyModeEnabled ? 10 : 0)

                                VStack(alignment: .leading, spacing: 6) {
                                    Text(item.title)
                                        .font(.headline)
                                        .foregroundStyle(.primary)
                                        .lineLimit(2)
                                    Text("共 \(item.totalEpisodes) 集 · 已下 \(item.downloadedEpisodes) · 已传 \(item.uploadedEpisodes)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    HStack {
                                        Text(item.completed == 1 ? "已完结" : "追更中")
                                            .font(.caption2.bold())
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 4)
                                            .background(item.completed == 1 ? Color.green.opacity(0.16) : Color.blue.opacity(0.16), in: Capsule())
                                        if item.failedCount > 0 {
                                            Text("失败 \(item.failedCount)")
                                                .font(.caption2.bold())
                                                .foregroundStyle(.red)
                                        }
                                    }
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .foregroundStyle(.secondary)
                            }
                            .padding(12)
                            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func actionPill(_ title: String, systemImage: String, isPrimary: Bool) -> some View {
        Label(title, systemImage: systemImage)
            .font(.subheadline.weight(.semibold))
            .frame(maxWidth: .infinity)
            .frame(height: 38)
            .background(isPrimary ? Color.blue : Color.blue.opacity(0.12), in: Capsule())
            .foregroundStyle(isPrimary ? .white : .blue)
    }

    private var manualAddSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("手动添加")
                .font(.headline)
            HStack {
                TextField("粘贴黄果短剧详情页或播放页 URL", text: $manualURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .textFieldStyle(.roundedBorder)
                Button {
                    let url = manualURL.trimmingCharacters(in: .whitespacesAndNewlines)
                    runningID = url
                    Task {
                        await viewModel.addHuangguoSeries(url: url)
                        manualURL = ""
                        runningID = ""
                    }
                } label: {
                    if runningID == manualURL.trimmingCharacters(in: .whitespacesAndNewlines), !runningID.isEmpty {
                        ProgressView()
                    } else {
                        Text("添加")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(manualURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

struct HuangguoCatalogDetailView: View {
    @EnvironmentObject private var viewModel: AppViewModel
    let item: HuangguoCatalogItem
    @State private var running = ""

    var body: some View {
        List {
            Section {
                KFImage(viewModel.client().proxiedImageURL(item.coverURL))
                    .placeholder { ProgressView() }
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity)
                    .blur(radius: viewModel.isPrivacyModeEnabled ? 12 : 0)
                Text(item.title)
                    .font(.headline)
                if !item.remark.isEmpty {
                    LabeledContent("状态", value: item.remark)
                }
                LabeledContent("来源 ID", value: item.id)
            }

            Section("操作") {
                Button {
                    running = "online"
                    Task {
                        await viewModel.loadHuangguoOnline(detailURL: item.detailURL)
                        running = ""
                    }
                } label: {
                    running == "online" ? AnyView(ProgressView()) : AnyView(Label("解析在线播放分集", systemImage: "play.circle"))
                }
                Button {
                    running = "add"
                    Task {
                        await viewModel.addHuangguoSeries(url: item.detailURL)
                        running = ""
                    }
                } label: {
                    running == "add" ? AnyView(ProgressView()) : AnyView(Label("自动入库并下载", systemImage: "plus.circle"))
                }
            }

            if let online = viewModel.selectedHuangguoOnline, online.detailURL == item.detailURL || online.id == item.id {
                Section("分集") {
                    ForEach(online.episodes) { episode in
                        Button {
                            viewModel.play(
                                title: "\(online.title) 第\(episode.ep)集",
                                url: viewModel.client().huangguoOnlinePlayURL(playURL: episode.playURL, ep: episode.ep)
                            )
                        } label: {
                            Label("第 \(episode.ep) 集", systemImage: episode.locked ? "lock" : "play.circle")
                        }
                        .disabled(episode.locked || episode.playURL.isEmpty)
                    }
                }
            }
        }
        .navigationTitle("黄果详情")
        .navigationBarTitleDisplayMode(.inline)
        .scrollContentBackground(.hidden)
        .background(Color(.systemGroupedBackground))
    }
}

struct HuangguoSeriesDetailView: View {
    @EnvironmentObject private var viewModel: AppViewModel
    let series: HuangguoSeries
    @State private var runningID = ""

    var body: some View {
        List {
            Section {
                KFImage(viewModel.client().huangguoCoverURL(seriesID: series.id))
                    .placeholder { ProgressView() }
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity)
                    .blur(radius: viewModel.isPrivacyModeEnabled ? 12 : 0)
                Text(series.title)
                    .font(.headline)
                LabeledContent("集数", value: "共 \(series.totalEpisodes) · 已下 \(series.downloadedEpisodes) · 已传 \(series.uploadedEpisodes)")
                LabeledContent("状态", value: series.completed == 1 ? "已完结" : "追更中")
            }

            Section("操作") {
                Button("检查追更") { run(.check(series.id), id: "check") }
                Button("重新刮削") { run(.rescrape(series.id), id: "rescrape") }
                Button("下载缺失分集") { run(.downloadMissing(series.id), id: "missing") }
                Button(series.completed == 1 ? "恢复追更" : "标记完结") {
                    run(.complete(series.id, series.completed != 1), id: "complete")
                }
            }

            Section("分集") {
                if viewModel.selectedHuangguoEpisodes.isEmpty {
                    ContentUnavailableView("暂无分集", systemImage: "list.number")
                } else {
                    ForEach(viewModel.selectedHuangguoEpisodes) { episode in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("第 \(episode.ep) 集")
                                    .font(.headline)
                                Spacer()
                                statusLabel(episode.state)
                                uploadLabel(episode.uploadState)
                            }
                            ProgressView(value: min(1, max(0, episode.progress)))
                            if !episode.message.isEmpty {
                                Text(episode.message)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            if !episode.error.isEmpty {
                                Text(episode.error)
                                    .font(.caption)
                                    .foregroundStyle(.red)
                            }
                            HStack {
                                if !episode.filePath.isEmpty {
                                    Button("播放本地") {
                                        viewModel.play(title: "\(series.title) 第\(episode.ep)集", url: viewModel.client().localMediaPlayURL(path: episode.filePath))
                                    }
                                    .buttonStyle(.bordered)
                                }
                                if !episode.playURL.isEmpty {
                                    Button("在线播放") {
                                        viewModel.play(title: "\(series.title) 第\(episode.ep)集", url: viewModel.client().huangguoOnlinePlayURL(playURL: episode.playURL, ep: episode.ep))
                                    }
                                    .buttonStyle(.bordered)
                                }
                                Button(episode.state == "completed" ? "重下" : "下载") {
                                    run(.downloadEpisode(episode.id), id: episode.id)
                                }
                                .buttonStyle(.borderedProminent)
                                if episode.uploadState == "failed" {
                                    Button("重传") {
                                        run(.retryUpload(episode.id), id: "upload-\(episode.id)")
                                    }
                                    .buttonStyle(.bordered)
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }

            Section {
                Button(role: .destructive) {
                    run(.delete(series.id, false), id: "delete")
                } label: {
                    Label("删除追剧记录", systemImage: "trash")
                }
            }
        }
        .navigationTitle("短剧分集")
        .navigationBarTitleDisplayMode(.inline)
        .scrollContentBackground(.hidden)
        .background(Color(.systemGroupedBackground))
        .task {
            await viewModel.loadHuangguoEpisodes(series)
        }
    }

    private func run(_ action: HuangguoAction, id: String) {
        runningID = id
        Task {
            await viewModel.runHuangguoAction(action)
            runningID = ""
        }
    }

    private func statusLabel(_ state: String) -> some View {
        Text(stateText(state))
            .font(.caption2.bold())
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(stateColor(state).opacity(0.16), in: Capsule())
            .foregroundStyle(stateColor(state))
    }

    private func uploadLabel(_ state: String) -> some View {
        Text(uploadText(state))
            .font(.caption2.bold())
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.blue.opacity(0.12), in: Capsule())
            .foregroundStyle(.blue)
    }

    private func stateText(_ state: String) -> String {
        switch state {
        case "completed": return "已下载"
        case "running": return "下载中"
        case "queued": return "排队中"
        case "failed": return "失败"
        default: return "未下载"
        }
    }

    private func uploadText(_ state: String) -> String {
        switch state {
        case "uploaded": return "已传115"
        case "uploading": return "上传中"
        case "failed": return "上传失败"
        case "waiting_complete": return "待完结"
        case "retry": return "待重传"
        case "skipped": return "仅本地"
        default: return "待上传"
        }
    }

    private func stateColor(_ state: String) -> Color {
        switch state {
        case "completed": return .green
        case "running": return .blue
        case "queued": return .orange
        case "failed": return .red
        default: return .secondary
        }
    }
}
