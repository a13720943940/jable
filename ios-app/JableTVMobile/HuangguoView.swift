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
            .refreshable {
                if selectedFilter == "catalog" {
                    await viewModel.refreshHuangguoCatalog(force: true)
                } else {
                    await viewModel.refreshHuangguoSeries()
                }
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
    @Environment(\.dismiss) private var dismiss
    let item: HuangguoCatalogItem
    @State private var running = ""

    var body: some View {
        let online = matchingOnline
        ZStack {
            huangguoPoster(url: item.coverURL, proxied: true)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea()
                .blur(radius: viewModel.isPrivacyModeEnabled ? 18 : 10)
                .opacity(0.42)

            LinearGradient(
                colors: [.white.opacity(0.34), Color(.systemBackground).opacity(0.78), Color(.systemBackground)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            ScrollView {
                VStack(spacing: 22) {
                    hero(online: online)
                    actionRow
                    if let online {
                        onlineEpisodes(online)
                    } else {
                        loadingEpisodesHint
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 92)
                .padding(.bottom, 110)
            }
        }
        .navigationTitle(item.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.left")
                        .font(.headline.bold())
                        .frame(width: 44, height: 44)
                        .background(.ultraThinMaterial, in: Circle())
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await viewModel.loadHuangguoOnline(detailURL: item.detailURL) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.headline.bold())
                        .frame(width: 44, height: 44)
                        .background(.ultraThinMaterial, in: Circle())
                }
            }
        }
        .task {
            if matchingOnline == nil {
                await viewModel.loadHuangguoOnline(detailURL: item.detailURL)
            }
        }
    }

    private var matchingOnline: HuangguoOnlineSeries? {
        guard let online = viewModel.selectedHuangguoOnline else { return nil }
        return (online.detailURL == item.detailURL || online.id == item.id) ? online : nil
    }

    private func hero(online: HuangguoOnlineSeries?) -> some View {
        VStack(spacing: 14) {
            huangguoPoster(url: online?.coverURL.isEmpty == false ? online?.coverURL ?? item.coverURL : item.coverURL, proxied: true)
                .frame(width: 150, height: 225)
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                .shadow(color: .black.opacity(0.20), radius: 20, x: 0, y: 10)
                .blur(radius: viewModel.isPrivacyModeEnabled ? 12 : 0)

            Text(online?.title ?? item.title)
                .font(.title2.bold())
                .multilineTextAlignment(.center)
                .lineLimit(2)

            Text(metaText(online: online))
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button {
                if let first = online?.episodes.first(where: { !$0.locked && !$0.playURL.isEmpty }) {
                    play(episode: first, in: online!)
                } else {
                    Task { await viewModel.loadHuangguoOnline(detailURL: item.detailURL) }
                }
            } label: {
                Label("播放", systemImage: "play.fill")
                    .font(.subheadline.bold())
                    .frame(maxWidth: 260)
                    .frame(height: 44)
                    .background(.white.opacity(0.94), in: Capsule())
                    .foregroundStyle(.black.opacity(0.82))
            }
        }
    }

    private var actionRow: some View {
        HStack(spacing: 12) {
            Button {
                running = "online"
                Task {
                    await viewModel.loadHuangguoOnline(detailURL: item.detailURL)
                    running = ""
                }
            } label: {
                detailActionLabel(title: "解析", systemImage: "play.circle.fill", active: running == "online")
            }
            Button {
                running = "add"
                Task {
                    await viewModel.addHuangguoSeries(url: item.detailURL)
                    running = ""
                }
            } label: {
                detailActionLabel(title: "入库下载", systemImage: "plus.circle.fill", active: running == "add")
            }
        }
    }

    private func onlineEpisodes(_ online: HuangguoOnlineSeries) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("分集")
                .font(.title3.bold())
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                ForEach(online.episodes) { episode in
                    Button {
                        play(episode: episode, in: online)
                    } label: {
                        VStack(spacing: 4) {
                            Image(systemName: episode.locked ? "lock.fill" : "play.fill")
                                .font(.caption.bold())
                            Text("第 \(episode.ep) 集")
                                .font(.subheadline.bold())
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 58)
                        .background(.white.opacity(0.82), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(episode.locked || episode.playURL.isEmpty)
                    .opacity(episode.locked || episode.playURL.isEmpty ? 0.45 : 1)
                }
            }
        }
    }

    private var loadingEpisodesHint: some View {
        ProgressView(viewModel.isLoadingHuangguo ? "正在解析分集…" : "等待分集数据")
            .frame(maxWidth: .infinity)
            .padding(28)
            .background(.white.opacity(0.72), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func play(episode: HuangguoOnlineEpisode, in online: HuangguoOnlineSeries) {
        viewModel.play(
            title: "\(online.title) 第\(episode.ep)集",
            url: viewModel.client().huangguoOnlinePlayURL(playURL: episode.playURL, ep: episode.ep)
        )
    }

    private func metaText(online: HuangguoOnlineSeries?) -> String {
        let episodeCount = online?.episodes.count ?? 0
        let parts = [item.remark, episodeCount > 0 ? "共 \(episodeCount) 集" : "", item.score.isEmpty ? "" : "评分 \(item.score)"]
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

struct HuangguoSeriesDetailView: View {
    @EnvironmentObject private var viewModel: AppViewModel
    @Environment(\.dismiss) private var dismiss
    let series: HuangguoSeries
    @State private var runningID = ""

    var body: some View {
        ZStack {
            huangguoPoster(url: series.coverURL, proxied: true, fallbackSeriesID: series.id)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea()
                .blur(radius: viewModel.isPrivacyModeEnabled ? 18 : 10)
                .opacity(0.42)

            LinearGradient(
                colors: [.white.opacity(0.34), Color(.systemBackground).opacity(0.78), Color(.systemBackground)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            ScrollView {
                VStack(spacing: 22) {
                    hero
                    actionGrid
                    episodeGrid
                    deleteButton
                }
                .padding(.horizontal, 20)
                .padding(.top, 92)
                .padding(.bottom, 110)
            }
        }
        .navigationTitle(series.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.left")
                        .font(.headline.bold())
                        .frame(width: 44, height: 44)
                        .background(.ultraThinMaterial, in: Circle())
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("检查追更") { run(.check(series.id), id: "check") }
                    Button("重新刮削") { run(.rescrape(series.id), id: "rescrape") }
                    Button("下载缺失分集") { run(.downloadMissing(series.id), id: "missing") }
                    Button(series.completed == 1 ? "恢复追更" : "标记完结") {
                        run(.complete(series.id, series.completed != 1), id: "complete")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.headline.bold())
                        .frame(width: 44, height: 44)
                        .background(.ultraThinMaterial, in: Circle())
                }
            }
        }
        .task {
            await viewModel.loadHuangguoEpisodes(series)
        }
    }

    private var hero: some View {
        VStack(spacing: 14) {
            huangguoPoster(url: series.coverURL, proxied: true, fallbackSeriesID: series.id)
                .frame(width: 150, height: 225)
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                .shadow(color: .black.opacity(0.20), radius: 20, x: 0, y: 10)
                .blur(radius: viewModel.isPrivacyModeEnabled ? 12 : 0)

            Text(series.title)
                .font(.title2.bold())
                .multilineTextAlignment(.center)
                .lineLimit(2)

            Text("黄果 · 共 \(series.totalEpisodes) 集 · 已下 \(series.downloadedEpisodes) · 已传 \(series.uploadedEpisodes)")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button {
                if let first = viewModel.selectedHuangguoEpisodes.first(where: { !$0.filePath.isEmpty || !$0.playURL.isEmpty }) {
                    play(first)
                }
            } label: {
                Label("播放", systemImage: "play.fill")
                    .font(.subheadline.bold())
                    .frame(maxWidth: 260)
                    .frame(height: 44)
                    .background(.white.opacity(0.94), in: Capsule())
                    .foregroundStyle(.black.opacity(0.82))
            }
            .disabled(viewModel.selectedHuangguoEpisodes.allSatisfy { $0.filePath.isEmpty && $0.playURL.isEmpty })
        }
    }

    private var actionGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
            Button { run(.check(series.id), id: "check") } label: {
                detailActionLabel(title: "检查追更", systemImage: "arrow.clockwise", active: runningID == "check")
            }
            Button { run(.rescrape(series.id), id: "rescrape") } label: {
                detailActionLabel(title: "重新刮削", systemImage: "sparkles", active: runningID == "rescrape")
            }
            Button { run(.downloadMissing(series.id), id: "missing") } label: {
                detailActionLabel(title: "下载缺失", systemImage: "icloud.and.arrow.down", active: runningID == "missing")
            }
            Button { run(.complete(series.id, series.completed != 1), id: "complete") } label: {
                detailActionLabel(title: series.completed == 1 ? "恢复追更" : "标记完结", systemImage: "checkmark.seal", active: runningID == "complete")
            }
        }
    }

    private var episodeGrid: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("分集")
                .font(.title3.bold())
            if viewModel.selectedHuangguoEpisodes.isEmpty {
                ProgressView("正在加载分集…")
                    .frame(maxWidth: .infinity)
                    .padding(28)
                    .background(.white.opacity(0.72), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            } else {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                    ForEach(viewModel.selectedHuangguoEpisodes) { episode in
                        Button {
                            if episode.filePath.isEmpty && episode.playURL.isEmpty {
                                run(.downloadEpisode(episode.id), id: episode.id)
                            } else {
                                play(episode)
                            }
                        } label: {
                            VStack(spacing: 5) {
                                Text("第 \(episode.ep) 集")
                                    .font(.subheadline.bold())
                                Text(episodeSubtitle(episode))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                ProgressView(value: min(1, max(0, episode.progress)))
                                    .opacity(episode.state == "running" ? 1 : 0)
                            }
                            .frame(maxWidth: .infinity)
                            .frame(height: 70)
                            .padding(.horizontal, 8)
                            .background(.white.opacity(0.82), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var deleteButton: some View {
        Button(role: .destructive) {
            run(.delete(series.id, false), id: "delete")
        } label: {
            Label("删除追剧记录", systemImage: "trash")
                .frame(maxWidth: .infinity)
                .frame(height: 44)
        }
        .buttonStyle(.bordered)
    }

    private func run(_ action: HuangguoAction, id: String) {
        runningID = id
        Task {
            await viewModel.runHuangguoAction(action)
            runningID = ""
        }
    }

    private func play(_ episode: HuangguoEpisode) {
        if !episode.filePath.isEmpty {
            viewModel.play(title: "\(series.title) 第\(episode.ep)集", url: viewModel.client().localMediaPlayURL(path: episode.filePath))
        } else if !episode.playURL.isEmpty {
            viewModel.play(title: "\(series.title) 第\(episode.ep)集", url: viewModel.client().huangguoOnlinePlayURL(playURL: episode.playURL, ep: episode.ep))
        }
    }

    private func episodeSubtitle(_ episode: HuangguoEpisode) -> String {
        if episode.state == "completed" { return uploadText(episode.uploadState) }
        if episode.state == "running" { return "\(Int(episode.progress * 100))%" }
        return stateText(episode.state)
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

private func huangguoPoster(url: String, proxied: Bool, fallbackSeriesID: String = "") -> some View {
    HuangguoPosterImage(url: url, proxied: proxied, fallbackSeriesID: fallbackSeriesID)
}

private struct HuangguoPosterImage: View {
    @EnvironmentObject private var viewModel: AppViewModel
    let url: String
    let proxied: Bool
    let fallbackSeriesID: String

    var body: some View {
        KFImage(imageURL)
            .placeholder {
                ZStack {
                    LinearGradient(colors: [.orange.opacity(0.28), .blue.opacity(0.18)], startPoint: .topLeading, endPoint: .bottomTrailing)
                    Image(systemName: "play.rectangle.on.rectangle")
                        .font(.system(size: 46, weight: .bold))
                        .foregroundStyle(.white.opacity(0.72))
                }
            }
            .resizable()
            .scaledToFill()
    }

    private var imageURL: URL? {
        if proxied, !url.isEmpty {
            return viewModel.client().proxiedImageURL(url)
        }
        if !fallbackSeriesID.isEmpty {
            return viewModel.client().huangguoCoverURL(seriesID: fallbackSeriesID)
        }
        return URL(string: url)
    }
}

private func detailActionLabel(title: String, systemImage: String, active: Bool) -> some View {
    HStack(spacing: 8) {
        if active {
            ProgressView()
        } else {
            Image(systemName: systemImage)
        }
        Text(title)
            .font(.subheadline.bold())
            .lineLimit(1)
            .minimumScaleFactor(0.8)
    }
    .frame(maxWidth: .infinity)
    .frame(height: 44)
    .background(.white.opacity(0.84), in: Capsule())
    .foregroundStyle(.primary)
}
