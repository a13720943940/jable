import SwiftUI

struct ManualTaskView: View {
    @EnvironmentObject private var viewModel: AppViewModel
    @State private var mode = "download"

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("模式", selection: $mode) {
                        Text("下载").tag("download")
                        Text("刮削").tag("scrape")
                    }
                    .pickerStyle(.segmented)
                }

                if mode == "download" {
                    Section("媒体地址") {
                        TextField("m3u8 / mp4 / mpd", text: $viewModel.manualURL, axis: .vertical)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                } else {
                    Section("文件或目录路径") {
                        TextField("/media/待刮削/ABC-123.strm", text: $viewModel.scrapePath, axis: .vertical)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                }

                Section("影片信息") {
                    TextField("标题", text: $viewModel.manualTitle)
                    TextField("番号", text: $viewModel.manualCatalog)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                    TextField("演员", text: $viewModel.manualPerformer)
                }

                Section("任务设置") {
                    Stepper("下载线程 \(viewModel.manualThreads)", value: $viewModel.manualThreads, in: 1 ... 8)
                    Toggle("下载完成后整理", isOn: $viewModel.organizeEnabled)
                    Toggle("允许重复下载", isOn: $viewModel.allowDuplicate)
                }

                Section {
                    Button {
                        Task {
                            if mode == "download" {
                                await viewModel.submitManualTask()
                            } else {
                                await viewModel.submitManualScrape()
                            }
                        }
                    } label: {
                        Label(mode == "download" ? "加入下载队列" : "加入刮削队列", systemImage: mode == "download" ? "arrow.down.circle" : "wand.and.sparkles")
                            .frame(maxWidth: .infinity)
                    }
                    .disabled(mode == "download" ? viewModel.manualURL.isEmpty : viewModel.scrapePath.isEmpty)
                }

                Section("状态") {
                    Text(viewModel.statusMessage)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("手动任务")
            .scrollContentBackground(.hidden)
            .background(LinearGradient(colors: [Color(.systemGroupedBackground), Color.blue.opacity(0.10), Color.cyan.opacity(0.06)], startPoint: .topLeading, endPoint: .bottomTrailing))
            .toolbarBackground(.visible, for: .navigationBar)
        }
    }
}
