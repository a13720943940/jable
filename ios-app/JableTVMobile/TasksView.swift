import SwiftUI
import Kingfisher

struct TasksView: View {
    @EnvironmentObject private var viewModel: AppViewModel
    @State private var source = "all"

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 18) {
                        HStack(spacing: 14) {
                            Image(systemName: "arrow.down.circle.fill")
                                .font(.largeTitle)
                                .foregroundStyle(.blue)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("下载中心")
                                    .font(.largeTitle.bold())
                                Text("\(totalTaskCount) 条记录 · 下拉同步最新状态")
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(.secondary)
                            }
                        }

                        HStack(spacing: 10) {
                            taskStat(title: "115", value: "\(viewModel.cloudTasks.count)", color: .blue)
                            taskStat(title: "本地", value: "\(viewModel.tasks.count)", color: .cyan)
                            taskStat(title: "黄果", value: "\(viewModel.huangguoEpisodeTasks.count)", color: .orange)
                        }

                        Picker("来源", selection: $source) {
                            Text("全部").tag("all")
                            Text("115").tag("cloud")
                            Text("本地").tag("local")
                            Text("黄果").tag("huangguo")
                        }
                        .pickerStyle(.segmented)
                    }
                    .padding(18)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
                }
                .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 8, trailing: 16))
                .listRowBackground(Color.clear)

                if source == "all" || source == "cloud" {
                    Section("115 离线") {
                        if viewModel.filteredCloudTasks.isEmpty {
                            ContentUnavailableView("暂无 115 任务", systemImage: "cloud")
                        } else {
                            ForEach(viewModel.filteredCloudTasks) { task in
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack(alignment: .top, spacing: 12) {
                                        KFImage(viewModel.client().proxiedImageURL(task.coverURL))
                                            .placeholder {
                                                Image(systemName: "cloud")
                                                    .foregroundStyle(.secondary)
                                            }
                                            .resizable()
                                            .scaledToFill()
                                            .frame(width: 62, height: 88)
                                            .clipShape(RoundedRectangle(cornerRadius: 8))
                                            .blur(radius: viewModel.isPrivacyModeEnabled ? 10 : 0)

                                        VStack(alignment: .leading, spacing: 6) {
                                            HStack {
                                                Text(task.catalog.isEmpty ? task.title : task.catalog)
                                                    .font(.headline)
                                                Spacer()
                                                Text(task.state)
                                                    .font(.caption2.bold())
                                                    .foregroundStyle(task.state == "completed" ? .green : .orange)
                                            }
                                            Text(task.title)
                                                .font(.footnote)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(2)
                                            Text(task.message.isEmpty ? task.state : task.message)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(2)
                                            if !task.filePath.isEmpty {
                                                Text(task.filePath)
                                                    .font(.caption)
                                                    .foregroundStyle(.secondary)
                                                    .lineLimit(1)
                                            }
                                        }
                                    }
                                }
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    play(task)
                                }
                                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                    Button(role: .destructive) {
                                        Task { await viewModel.deleteCloudTask(task) }
                                    } label: {
                                        Label("删除", systemImage: "trash")
                                    }
                                }
                            }
                        }
                    }
                }

                if source == "all" || source == "local" {
                    Section("本地下载") {
                        if viewModel.filteredTasks.isEmpty {
                            ContentUnavailableView("暂无本地任务", systemImage: "tray")
                        } else {
                            ForEach(viewModel.filteredTasks) { task in
                                VStack(alignment: .leading, spacing: 10) {
                                    HStack(alignment: .top, spacing: 12) {
                                        KFImage(viewModel.client().proxiedImageURL(task.coverURL))
                                            .placeholder {
                                                Image(systemName: "film")
                                                    .foregroundStyle(.secondary)
                                            }
                                            .resizable()
                                            .scaledToFill()
                                            .frame(width: 62, height: 88)
                                            .clipShape(RoundedRectangle(cornerRadius: 8))
                                            .blur(radius: viewModel.isPrivacyModeEnabled ? 10 : 0)

                                        VStack(alignment: .leading, spacing: 6) {
                                            HStack {
                                                Text(task.catalog.isEmpty ? task.title : task.catalog)
                                                    .font(.headline)
                                                Spacer()
                                                Text("\(Int(task.progress * 100))%")
                                                    .font(.subheadline.monospacedDigit())
                                                    .foregroundStyle(.secondary)
                                            }

                                            Text(task.title)
                                                .font(.footnote)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(2)

                                            ProgressView(value: min(max(task.progress, 0), 1))

                                            HStack {
                                                Text(label(for: task.downloadStep, title: "下载"))
                                                Text(label(for: task.scrapeStep, title: "刮削"))
                                                Text(label(for: task.organizeStep, title: "整理"))
                                            }
                                            .font(.caption)
                                            .foregroundStyle(.secondary)

                                            HStack {
                                                Text(task.speed)
                                                Text(task.size)
                                                Text(task.eta)
                                            }
                                            .font(.caption)
                                            .foregroundStyle(.secondary)

                                            if !task.resultMessage.isEmpty {
                                                Text(task.resultMessage)
                                                    .font(.caption)
                                                    .foregroundStyle(task.state == "completed" ? .green : .orange)
                                            }
                                        }
                                    }
                                }
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    if task.state == "completed" {
                                        viewModel.play(title: task.title, url: viewModel.client().localTaskPlayURL(task.id))
                                    }
                                }
                                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                    if task.state == "failed" || task.state == "interrupted" {
                                        Button {
                                            Task { await viewModel.retry(task) }
                                        } label: {
                                            Label("重试", systemImage: "arrow.counterclockwise")
                                        }
                                        .tint(.orange)
                                    }
                                }
                            }
                        }
                    }
                }

                if source == "all" || source == "huangguo" {
                    Section("黄果下载") {
                        if viewModel.filteredHuangguoEpisodeTasks.isEmpty {
                            ContentUnavailableView("暂无黄果下载记录", systemImage: "bolt.circle")
                        } else {
                            ForEach(viewModel.filteredHuangguoEpisodeTasks) { task in
                                VStack(alignment: .leading, spacing: 10) {
                                    HStack(alignment: .top, spacing: 12) {
                                        KFImage(viewModel.client().huangguoCoverURL(seriesID: task.seriesID))
                                            .placeholder {
                                                Image(systemName: "bolt.circle")
                                                    .foregroundStyle(.secondary)
                                            }
                                            .resizable()
                                            .scaledToFill()
                                            .frame(width: 62, height: 88)
                                            .clipShape(RoundedRectangle(cornerRadius: 8))
                                            .blur(radius: viewModel.isPrivacyModeEnabled ? 10 : 0)

                                        VStack(alignment: .leading, spacing: 6) {
                                            HStack {
                                                Text(task.seriesTitle.isEmpty ? "黄果短剧" : task.seriesTitle)
                                                    .font(.headline)
                                                    .lineLimit(1)
                                                Spacer()
                                                Text(hgStateText(task.state))
                                                    .font(.caption2.bold())
                                                    .foregroundStyle(hgStateColor(task.state))
                                            }

                                            Text(hgEpisodeTitle(task))
                                                .font(.footnote)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(2)

                                            if showsHgProgress(task) {
                                                ProgressView(value: normalizedHgProgress(task.progress))
                                            }

                                            hgBadges(task)

                                            Text(hgMessage(task))
                                                .font(.caption)
                                                .foregroundStyle(hgMessageColor(task))
                                                .lineLimit(2)
                                        }
                                    }
                                }
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    play(task)
                                }
                                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                    if canRetryHgTask(task) {
                                        Button {
                                            Task { await viewModel.runHuangguoAction(.downloadEpisode(task.id)) }
                                        } label: {
                                            Label("重试", systemImage: "arrow.counterclockwise")
                                        }
                                        .tint(.orange)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .searchable(text: $viewModel.taskSearchText, prompt: "搜索任务")
            .listStyle(.insetGrouped)
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .scrollContentBackground(.hidden)
            .background(LinearGradient(colors: [Color(.systemGroupedBackground), Color.blue.opacity(0.16), Color.orange.opacity(0.08), Color(.systemBackground)], startPoint: .topLeading, endPoint: .bottomTrailing))
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        ManualTaskView()
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .refreshable {
                await viewModel.refreshTasks()
            }
        }
    }

    private var totalTaskCount: Int {
        viewModel.cloudTasks.count + viewModel.tasks.count + viewModel.huangguoEpisodeTasks.count
    }

    private func taskStat(title: String, value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value)
                .font(.title3.bold())
                .monospacedDigit()
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func label(for state: String, title: String) -> String {
        switch state {
        case "succeeded":
            return "\(title)完成"
        case "failed":
            return "\(title)失败"
        case "running":
            return "\(title)中"
        case "skipped":
            return "\(title)跳过"
        default:
            return "\(title)等待"
        }
    }

    private func play(_ task: CloudTask) {
        if let pickcode = task.pickcode, !pickcode.isEmpty {
            viewModel.play(title: task.title, url: viewModel.client().pickcodeURL(pickcode))
        } else if let strmID = task.strmID, !strmID.isEmpty {
            let item = StrmItem(
                id: strmID,
                catalog: task.catalog,
                title: task.title,
                filePath: task.filePath,
                size: nil,
                createdAt: task.createdAt,
                posterPath: "",
                strmPath: "",
                pickcode: task.pickcode,
                coverURL: task.coverURL
            )
            viewModel.play(title: task.title, url: viewModel.client().streamURL(for: item))
        }
    }

    private func play(_ task: HuangguoEpisodeTask) {
        guard !task.filePath.isEmpty else { return }
        let title = "\(task.seriesTitle.isEmpty ? "黄果短剧" : task.seriesTitle) 第\(task.ep)集"
        viewModel.play(title: title, url: viewModel.client().localMediaPlayURL(path: task.filePath))
    }

    private func normalizedHgProgress(_ value: Double) -> Double {
        value > 1 ? min(max(value / 100, 0), 1) : min(max(value, 0), 1)
    }

    private func hgStateText(_ state: String) -> String {
        switch state {
        case "completed":
            return "完成"
        case "running", "downloading", "processing":
            return "进行中"
        case "failed", "error":
            return "失败"
        case "queued":
            return "排队中"
        default:
            return "等待中"
        }
    }

    private func hgUploadText(_ state: String) -> String {
        switch state {
        case "uploaded":
            return "已上传 115"
        case "uploading":
            return "上传中"
        case "failed":
            return "上传失败"
        case "waiting_complete":
            return "等待完结上传"
        case "retry":
            return "等待重传"
        default:
            return "未上传"
        }
    }

    private func hgEpisodeTitle(_ task: HuangguoEpisodeTask) -> String {
        task.episodeTitle.isEmpty ? "第 \(task.ep) 集" : "第 \(task.ep) 集 · \(task.episodeTitle)"
    }

    private func canRetryHgTask(_ task: HuangguoEpisodeTask) -> Bool {
        ["failed", "pending", "queued"].contains(task.state)
    }

    private func showsHgProgress(_ task: HuangguoEpisodeTask) -> Bool {
        ["running", "queued", "pending"].contains(task.state)
    }

    private func hgBadges(_ task: HuangguoEpisodeTask) -> some View {
        HStack(spacing: 8) {
            Text(hgUploadText(task.uploadState))
            if !task.filePath.isEmpty {
                Text("本地完成")
            }
            if !task.uploadPath.isEmpty {
                Text("115 已记录")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func hgMessage(_ task: HuangguoEpisodeTask) -> String {
        if !task.error.isEmpty { return task.error }
        if !task.message.isEmpty { return task.message }
        return hgStateText(task.state)
    }

    private func hgMessageColor(_ task: HuangguoEpisodeTask) -> Color {
        task.error.isEmpty ? .secondary : .red
    }

    private func hgStateColor(_ state: String) -> Color {
        switch state {
        case "completed":
            return .green
        case "failed", "error":
            return .red
        case "running", "downloading", "processing":
            return .blue
        default:
            return .orange
        }
    }
}
