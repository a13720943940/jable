import SwiftUI
import Kingfisher

struct MediaLibraryView: View {
    @EnvironmentObject private var viewModel: AppViewModel
    @State private var source = "all"

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack {
                            Label("媒体库", systemImage: "play.square.stack.fill")
                                .font(.title3.bold())
                            Spacer()
                        }

                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                            LabeledContent("115 完成", value: "\(viewModel.heroStats?.cloudDone ?? viewModel.cloudTasks.filter { $0.state == "completed" }.count)")
                            LabeledContent("媒体库", value: "\(viewModel.heroStats?.strmCount ?? viewModel.strmItems.count)")
                            LabeledContent("本地文件", value: "\(viewModel.mediaFiles.count)")
                            LabeledContent("任务中", value: "\(viewModel.heroStats?.cloudActive ?? viewModel.cloudTasks.filter { $0.state != "completed" && $0.state != "failed" }.count)")
                        }
                        .font(.caption)
                    }
                    .padding(16)
                    .background(Color.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 24, style: .continuous))

                    sourceSegmentedControl
                        .padding(.top, 0)

                    if source == "all" || source == "115" {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("115 媒体库")
                                .font(.title3.bold())
                        if viewModel.filteredStrmItems.isEmpty {
                            ContentUnavailableView("暂无 115 媒体", systemImage: "play.square.stack")
                        } else {
                            LazyVStack(spacing: 10) {
                                ForEach(viewModel.filteredStrmItems) { item in
                                HStack(alignment: .top, spacing: 12) {
                                    KFImage(posterURL(item))
                                        .placeholder {
                                            Image(systemName: "play.square")
                                                .foregroundStyle(.secondary)
                                            }
                                            .resizable()
                                            .scaledToFill()
                                            .frame(width: 72, height: 96)
                                            .clipShape(RoundedRectangle(cornerRadius: 8))
                                            .blur(radius: viewModel.isPrivacyModeEnabled ? 10 : 0)

                                    VStack(alignment: .leading, spacing: 6) {
                                        HStack {
                                            Text(item.catalog.isEmpty ? "未识别番号" : item.catalog)
                                                .font(.headline)
                                            Spacer()
                                            Text("115")
                                                .font(.caption2.bold())
                                                .foregroundStyle(.blue)
                                        }
                                        Text(item.title)
                                            .font(.footnote)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(2)
                                        if !item.filePath.isEmpty {
                                            Text(item.filePath)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                        }
                                    }
                                }
                                .padding(12)
                                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    play(item)
                                }
                                }
                            }
                        }
                    }
                }

                if source == "all" || source == "files" {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("本地媒体库")
                            .font(.title3.bold())
                        if viewModel.localLibrarySeries.isEmpty {
                            ContentUnavailableView("暂无本地媒体", systemImage: "folder", description: Text("本地下载入库或媒体目录扫描到视频后会显示在这里。"))
                        } else {
                            LazyVStack(spacing: 10) {
                                ForEach(viewModel.localLibrarySeries) { series in
                                NavigationLink {
                                    LocalLibraryDetailView(series: series)
                                } label: {
                                    HStack(alignment: .top, spacing: 12) {
                                        localCover(series)

                                        VStack(alignment: .leading, spacing: 6) {
                                            HStack {
                                                Text(series.catalog)
                                                    .font(.headline)
                                                    .lineLimit(1)
                                                Spacer()
                                                Text(series.source)
                                                    .font(.caption2.bold())
                                                    .foregroundStyle(series.source == "黄果" ? .orange : .green)
                                            }
                                            Text(series.title)
                                                .font(.footnote)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(2)
                                            Text("\(series.episodeCount) 个文件 · \(ByteCountFormatter.string(fromByteCount: series.totalSize, countStyle: .file))")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
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
            }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 16)
            }
            .searchable(text: $viewModel.mediaSearchText, prompt: "搜索番号、标题或路径")
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .overlay {
                if viewModel.isLoadingMedia && viewModel.strmItems.isEmpty && viewModel.mediaFiles.isEmpty {
                    ProgressView("正在加载媒体库…")
                        .padding()
                        .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 10))
                }
            }
            .background(LinearGradient(colors: [Color(.systemGroupedBackground), Color.blue.opacity(0.10), Color.cyan.opacity(0.06)], startPoint: .topLeading, endPoint: .bottomTrailing))
            .toolbar(.hidden, for: .navigationBar)
            .refreshable {
                await viewModel.refreshStats()
                await viewModel.refreshMedia()
            }
            .task {
                await viewModel.refreshStats()
            }
        }
    }

    private func posterURL(_ item: StrmItem) -> URL? {
        if !item.posterPath.isEmpty {
            return viewModel.client().absoluteURL("/api/strm-library/\(item.id)/poster")
        }
        return viewModel.client().proxiedImageURL(item.coverURL)
    }

    private func play(_ item: StrmItem) {
        if let pickcode = item.pickcode, !pickcode.isEmpty {
            viewModel.play(title: item.title, url: viewModel.client().pickcodeURL(pickcode))
        } else {
            viewModel.play(title: item.title, url: viewModel.client().streamURL(for: item))
        }
    }

    private var sourceSegmentedControl: some View {
        HStack(spacing: 0) {
            sourceSegment("全部", value: "all")
            sourceSegment("115", value: "115")
            sourceSegment("本地", value: "files")
        }
        .padding(3)
        .frame(height: 40)
        .background(Color(.systemGray5).opacity(0.72), in: Capsule())
    }

    private func sourceSegment(_ title: String, value: String) -> some View {
        Button {
            withAnimation(.snappy(duration: 0.2)) {
                source = value
            }
        } label: {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
                .frame(height: 34)
                .background(source == value ? Color(.systemBackground) : Color.clear, in: Capsule())
                .foregroundStyle(.primary)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func localCover(_ series: LocalLibrarySeries) -> some View {
        if series.source == "黄果", !series.coverPath.isEmpty {
            KFImage(viewModel.client().huangguoLocalCoverURL(seriesName: series.coverPath))
                .placeholder {
                    coverPlaceholder
                }
                .resizable()
                .scaledToFill()
                .frame(width: 72, height: 96)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .blur(radius: viewModel.isPrivacyModeEnabled ? 10 : 0)
        } else {
            coverPlaceholder
                .frame(width: 72, height: 96)
        }
    }

    private var coverPlaceholder: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(LinearGradient(colors: [.blue.opacity(0.20), .cyan.opacity(0.12)], startPoint: .topLeading, endPoint: .bottomTrailing))
            Image(systemName: "film.stack")
                .foregroundStyle(.blue)
        }
    }
}

struct LocalLibraryDetailView: View {
    @EnvironmentObject private var viewModel: AppViewModel
    let series: LocalLibrarySeries
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            cover
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea()
                .blur(radius: viewModel.isPrivacyModeEnabled ? 16 : 8)
                .opacity(0.58)

            LinearGradient(
                colors: [
                    .black.opacity(0.04),
                    Color(.systemBackground).opacity(0.55),
                    Color(.systemBackground).opacity(0.88),
                    Color(.systemBackground)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            ScrollView {
                VStack(spacing: 22) {
                    VStack(spacing: 14) {
                        cover
                            .frame(width: 176, height: 264)
                            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                            .shadow(color: .black.opacity(0.24), radius: 22, x: 0, y: 12)
                            .blur(radius: viewModel.isPrivacyModeEnabled ? 12 : 0)

                        Text(series.catalog)
                            .font(.title2.bold())
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                        Text("\(series.source) · 共 \(series.episodeCount) 集/文件 · \(ByteCountFormatter.string(fromByteCount: series.totalSize, countStyle: .file))")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        Text(series.title)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                            .padding(.horizontal, 24)

                        Button {
                            if let first = series.episodes.first {
                                viewModel.play(title: first.name, url: viewModel.client().localMediaPlayURL(path: first.path))
                            }
                        } label: {
                            Label("播放", systemImage: "play.fill")
                                .font(.subheadline.bold())
                                .frame(maxWidth: 260)
                                .frame(height: 44)
                                .background(.white.opacity(0.92), in: Capsule())
                                .foregroundStyle(.black.opacity(0.78))
                        }
                        .disabled(series.episodes.isEmpty)
                    }
                    .padding(.top, 86)

                    episodeSection
                        .padding(.bottom, 28)
                }
                .frame(maxWidth: 430)
                .padding(.horizontal, 18)
                .frame(maxWidth: .infinity)
            }
        }
        .navigationTitle(series.catalog)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
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
                    Button("刷新媒体库") {
                        Task { await viewModel.refreshMedia() }
                    }
                    if let first = series.episodes.first {
                        Button("播放第一集") {
                            viewModel.play(title: first.name, url: viewModel.client().localMediaPlayURL(path: first.path))
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }
            }
        }
    }

    private var episodeSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("分集")
                .font(.title3.bold())

            LazyVStack(spacing: 10) {
                ForEach(Array(stride(from: 0, to: series.episodes.count, by: 2)), id: \.self) { start in
                    HStack(spacing: 10) {
                        episodeButton(file: series.episodes[start], index: start)
                        if start + 1 < series.episodes.count {
                            episodeButton(file: series.episodes[start + 1], index: start + 1)
                        } else {
                            Color.clear
                                .frame(maxWidth: .infinity)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func episodeButton(file: MediaFile, index: Int) -> some View {
        Button {
            viewModel.play(title: file.name, url: viewModel.client().localMediaPlayURL(path: file.path))
        } label: {
            VStack(spacing: 4) {
                Text(episodeTitle(file.name, index: index))
                    .font(.subheadline.bold())
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Text(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 54)
            .background(Color(.secondarySystemGroupedBackground).opacity(0.86), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var cover: some View {
        if series.source == "黄果", !series.coverPath.isEmpty {
            KFImage(viewModel.client().huangguoLocalCoverURL(seriesName: series.coverPath))
                .placeholder { posterPlaceholder }
                .resizable()
                .scaledToFill()
        } else {
            posterPlaceholder
        }
    }

    private var posterPlaceholder: some View {
        ZStack {
            LinearGradient(colors: [.blue.opacity(0.38), .cyan.opacity(0.20), .black.opacity(0.20)], startPoint: .topLeading, endPoint: .bottomTrailing)
            Image(systemName: "play.rectangle.on.rectangle")
                .font(.system(size: 56, weight: .bold))
                .foregroundStyle(.white.opacity(0.78))
        }
    }

    private func episodeTitle(_ name: String, index: Int) -> String {
        if let match = name.range(of: #"第\d+集"#, options: .regularExpression) {
            return String(name[match])
        }
        return series.episodeCount == 1 ? "播放" : "\(index + 1)"
    }
}
