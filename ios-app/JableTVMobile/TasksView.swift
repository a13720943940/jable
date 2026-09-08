import SwiftUI
import Kingfisher

struct TasksView: View {
    @EnvironmentObject private var viewModel: AppViewModel
    @State private var source = "all"

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("来源", selection: $source) {
                        Text("全部").tag("all")
                        Text("115").tag("cloud")
                        Text("本地").tag("local")
                    }
                    .pickerStyle(.segmented)
                }

                Section {
                    LabeledContent("115 离线", value: "\(viewModel.cloudTasks.count)")
                    LabeledContent("本地下载", value: "\(viewModel.tasks.count)")
                }

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
            }
            .searchable(text: $viewModel.taskSearchText, prompt: "搜索任务")
            .listStyle(.insetGrouped)
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .scrollContentBackground(.hidden)
            .background(LinearGradient(colors: [Color(.systemGroupedBackground), Color.blue.opacity(0.10), Color.cyan.opacity(0.06)], startPoint: .topLeading, endPoint: .bottomTrailing))
            .toolbarBackground(.visible, for: .navigationBar)
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
}
