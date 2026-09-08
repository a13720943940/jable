import SwiftUI
import SwiftData
import Kingfisher

struct CatalogView: View {
    @EnvironmentObject private var viewModel: AppViewModel
    @Environment(\.modelContext) private var modelContext
    @Query private var catalogCaches: [CatalogPageCache]
    @State private var catalogFilter = "all"
    @AppStorage("catalogLayoutStyle") private var catalogLayoutStyle = "grid"

    private var displayedItems: [CatalogItem] {
        switch catalogFilter {
        case "numbered":
            return viewModel.filteredCatalogItems.filter { !$0.catalog.isEmpty }
        case "timed":
            return viewModel.filteredCatalogItems.filter { !$0.duration.isEmpty }
        default:
            return viewModel.filteredCatalogItems
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if viewModel.isLoadingCatalog && viewModel.catalogItems.isEmpty {
                    ZStack {
                        Color(.systemGroupedBackground).ignoresSafeArea()
                        ProgressView("正在加载影片库…")
                            .tint(.blue)
                    }
                } else if displayedItems.isEmpty {
                    ContentUnavailableView {
                        Label("影片浏览暂无内容", systemImage: "film.stack")
                    } description: {
                        Text(viewModel.statusMessage)
                    } actions: {
                        Button {
                            Task { await viewModel.refreshCatalog(force: true) }
                        } label: {
                            Label("刷新影片浏览", systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(.borderedProminent)
                    }
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            VStack(alignment: .leading, spacing: 10) {
                                HStack(alignment: .bottom) {
                                    VStack(alignment: .leading, spacing: 4) {
                                        HStack(spacing: 10) {
                                            Image("BrandLogo")
                                                .resizable()
                                                .scaledToFit()
                                                .frame(width: 34, height: 34)
                                                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                                            Button {
                                                withAnimation(.snappy) {
                                                    catalogLayoutStyle = catalogLayoutStyle == "grid" ? "large" : "grid"
                                                }
                                            } label: {
                                                HStack(spacing: 8) {
                                                    Text("影片浏览")
                                                        .font(.title2.bold())
                                                    Image(systemName: catalogLayoutStyle == "grid" ? "rectangle.grid.2x2" : "rectangle.stack")
                                                        .font(.subheadline.bold())
                                                }
                                                .foregroundStyle(.primary)
                                            }
                                            .buttonStyle(.plain)
                                        }
                                        Text("第 \(viewModel.catalogPage) 页 · \(displayedItems.count) 部")
                                            .font(.subheadline)
                                            .foregroundStyle(.blue)
                                        Text(viewModel.statusMessage)
                                            .font(.footnote)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                    Spacer()
                                }

                            }
                            .padding(16)
                            .background(
                                LinearGradient(
                                    colors: [Color.blue.opacity(0.22), Color.cyan.opacity(0.10), Color(.secondarySystemGroupedBackground).opacity(0.82)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                in: RoundedRectangle(cornerRadius: 18)
                            )

                            Picker("筛选", selection: $catalogFilter) {
                                Text("全部").tag("all")
                                Text("已识别").tag("numbered")
                                Text("有时长").tag("timed")
                            }
                            .pickerStyle(.segmented)

                            HStack {
                                Text("最新影片")
                                    .font(.headline)
                                    .foregroundStyle(.primary)
                                Spacer()
                                Text("第 \(viewModel.catalogPage) 页")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            if catalogLayoutStyle == "large" {
                                LazyVStack(spacing: 16) {
                                    ForEach(displayedItems) { item in
                                        NavigationLink {
                                            JableDetailView(item: item)
                                        } label: {
                                            CatalogLargeCard(item: item)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                                .transition(.opacity.combined(with: .move(edge: .bottom)))
                            } else {
                                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 18) {
                                    ForEach(displayedItems) { item in
                                        NavigationLink {
                                            JableDetailView(item: item)
                                        } label: {
                                            CatalogGridCard(item: item)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                                .transition(.opacity.combined(with: .move(edge: .top)))
                            }

                            HStack(spacing: 12) {
                                Button {
                                    Task {
                                        await viewModel.previousCatalogPage()
                                        saveCatalogCache()
                                    }
                                } label: {
                                    Label("上一页", systemImage: "chevron.left")
                                        .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.bordered)
                                .disabled(viewModel.catalogPage <= 1 || viewModel.isLoadingCatalog)

                                Button {
                                    Task {
                                        await viewModel.nextCatalogPage()
                                        saveCatalogCache()
                                    }
                                } label: {
                                    Label("下一页", systemImage: "chevron.right")
                                        .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(.blue)
                                .disabled(!viewModel.catalogHasNext || viewModel.isLoadingCatalog)
                            }
                        }
                        .padding(16)
                    }
                    .scrollIndicators(.hidden)
                    .scrollContentBackground(.hidden)
                    .background(LinearGradient(colors: [Color(.systemGroupedBackground), Color.blue.opacity(0.10), Color.cyan.opacity(0.06)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .refreshable {
                        await viewModel.refreshCatalog(page: viewModel.catalogPage, force: true)
                        saveCatalogCache()
                    }
                }
            }
            .searchable(text: $viewModel.searchText, prompt: "搜索番号或标题")
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.visible, for: .navigationBar)
            .safeAreaInset(edge: .bottom) {
                HStack {
                    Text(viewModel.statusMessage)
                        .font(.footnote)
                        .lineLimit(1)
                    Spacer()
                    Text("第 \(viewModel.catalogPage) 页 · \(displayedItems.count) 部")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal)
                .padding(.vertical, 10)
                .background(.regularMaterial)
            }
        }
    }

    private func saveCatalogCache() {
        guard let payload = viewModel.catalogCachePayload(), !viewModel.catalogItems.isEmpty else { return }
        let serverURL = viewModel.normalized(viewModel.serverURL)
        if let existing = catalogCaches.first(where: { $0.serverURL == serverURL && $0.page == viewModel.catalogPage }) {
            existing.payload = payload
            existing.hasNext = viewModel.catalogHasNext
            existing.pageSize = viewModel.catalogPageSize
            existing.updatedAt = Date()
        } else {
            modelContext.insert(CatalogPageCache(serverURL: serverURL, page: viewModel.catalogPage, payload: payload, hasNext: viewModel.catalogHasNext, pageSize: viewModel.catalogPageSize))
        }
        try? modelContext.save()
    }
}

private struct CatalogGridCard: View {
    @EnvironmentObject private var viewModel: AppViewModel
    let item: CatalogItem

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            poster(height: 112, cornerRadius: 10)
            Text(item.catalog.isEmpty ? "未识别番号" : item.catalog)
                .font(.subheadline.bold())
                .foregroundStyle(.primary)
                .lineLimit(1)
                .frame(height: 18, alignment: .leading)
            Text(item.title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .frame(minHeight: 34, alignment: .top)
        }
    }

    private func poster(height: CGFloat, cornerRadius: CGFloat) -> some View {
        ZStack(alignment: .bottomLeading) {
            KFImage(viewModel.client().proxiedImageURL(item.imageURL))
                .placeholder {
                    ZStack {
                        Rectangle().fill(Color.white.opacity(0.08))
                        Image(systemName: "film")
                            .foregroundStyle(.secondary)
                    }
                }
                .resizable()
                .scaledToFill()
                .frame(maxWidth: .infinity)
                .frame(height: height)
                .clipped()
                .blur(radius: viewModel.isPrivacyModeEnabled ? 10 : 0)
            LinearGradient(colors: [.clear, .black.opacity(0.74)], startPoint: .center, endPoint: .bottom)
            if !item.duration.isEmpty {
                Text(item.duration)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(.black.opacity(0.78), in: Capsule())
                    .padding(8)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

private struct CatalogLargeCard: View {
    @EnvironmentObject private var viewModel: AppViewModel
    let item: CatalogItem

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack(alignment: .bottomLeading) {
                KFImage(viewModel.client().proxiedImageURL(item.imageURL))
                    .placeholder {
                        ZStack {
                            Rectangle().fill(Color(.secondarySystemGroupedBackground))
                            Image(systemName: "film.stack")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: .infinity)
                    .frame(height: 210)
                    .clipped()
                    .blur(radius: viewModel.isPrivacyModeEnabled ? 10 : 0)
                LinearGradient(colors: [.clear, .black.opacity(0.82)], startPoint: .center, endPoint: .bottom)
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.catalog.isEmpty ? "未识别番号" : item.catalog)
                        .font(.title3.bold())
                    Text(item.title)
                        .font(.footnote)
                        .lineLimit(2)
                    if !item.duration.isEmpty {
                        Text(item.duration)
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.white.opacity(0.18), in: Capsule())
                    }
                }
                .foregroundStyle(.white)
                .padding(14)
            }
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .padding(10)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

struct JableDetailView: View {
    @EnvironmentObject private var viewModel: AppViewModel
    let item: CatalogItem
    @State private var runningAction: DetailAction?

    var body: some View {
        List {
            Section {
                KFImage(viewModel.client().proxiedImageURL(viewModel.selectedJableDetail?.coverURL ?? item.imageURL))
                    .placeholder {
                        ZStack {
                            Rectangle().fill(Color(.secondarySystemFill))
                            ProgressView()
                        }
                    }
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity)
                    .blur(radius: viewModel.isPrivacyModeEnabled ? 12 : 0)

                Text(viewModel.selectedJableDetail?.title ?? item.title)
                    .font(.headline)
                LabeledContent("番号", value: viewModel.selectedJableDetail?.catalog ?? item.catalog)
                LabeledContent("时长", value: item.duration.isEmpty ? "未知" : item.duration)
                LabeledContent("详情链接", value: item.detailURL)
            }

            Section("操作") {
                Button {
                    Task {
                        runningAction = .local
                        await viewModel.submitAutoTask(item)
                        runningAction = nil
                    }
                } label: {
                    if runningAction == .local {
                        ProgressView()
                    } else {
                        Label("本地下载入库", systemImage: "arrow.down.circle")
                    }
                }
                .disabled(runningAction != nil)

                Button {
                    Task {
                        runningAction = .cloud
                        await viewModel.submitSelectedToCloud()
                        runningAction = nil
                    }
                } label: {
                    if runningAction == .cloud {
                        ProgressView()
                    } else {
                        Label("离线到 115", systemImage: "cloud")
                    }
                }
                .disabled(runningAction != nil)

                Button {
                    Task {
                        runningAction = .capture
                        await viewModel.captureSelectedMedia()
                        runningAction = nil
                    }
                } label: {
                    if runningAction == .capture {
                        ProgressView()
                    } else {
                        Label("抓取 M3U8", systemImage: "link")
                    }
                }
                .disabled(runningAction != nil)

                if let captured = viewModel.capturedMedia {
                    Button {
                        viewModel.play(title: captured.title, url: URL(string: captured.mediaURL))
                    } label: {
                        Label("在线播放", systemImage: "play.circle")
                    }
                    Text(captured.mediaURL)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            .buttonStyle(.borderless)

            if viewModel.isLoadingDetail {
                Section {
                    ProgressView("正在读取详情…")
                }
            }

            if let detail = viewModel.selectedJableDetail {
                if !detail.samples.isEmpty {
                    Section("样张") {
                        ScrollView(.horizontal) {
                            LazyHStack(spacing: 12) {
                                ForEach(detail.samples, id: \.self) { sample in
                                    KFImage(viewModel.client().proxiedImageURL(sample))
                                        .placeholder {
                                            Image(systemName: "photo")
                                                .foregroundStyle(.secondary)
                                        }
                                        .resizable()
                                        .scaledToFill()
                                        .frame(width: 220, height: 140)
                                        .clipShape(RoundedRectangle(cornerRadius: 8))
                                        .blur(radius: viewModel.isPrivacyModeEnabled ? 12 : 0)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }

                Section("磁力链接") {
                    if detail.magnets.isEmpty {
                        ContentUnavailableView("暂无磁力链接", systemImage: "link.badge.plus")
                    } else {
                        ForEach(detail.magnets) { magnet in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(magnet.name.isEmpty ? "磁力链接" : magnet.name)
                                    .font(.headline)
                                HStack {
                                    if !magnet.size.isEmpty {
                                        Text(magnet.size)
                                    }
                                    if !magnet.files.isEmpty {
                                        Text(magnet.files)
                                    }
                                }
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                Button {
                                    Task {
                                        runningAction = .magnet(magnet.url)
                                        await viewModel.submitSelectedToCloud(sourceURL: magnet.url)
                                        runningAction = nil
                                    }
                                } label: {
                                    if runningAction == .magnet(magnet.url) {
                                        ProgressView()
                                    } else {
                                        Label("用此磁力离线到 115", systemImage: "cloud")
                                    }
                                }
                                .buttonStyle(.borderless)
                                .disabled(runningAction != nil)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(item.catalog.isEmpty ? "影片详情" : item.catalog)
        .navigationBarTitleDisplayMode(.inline)
        .scrollContentBackground(.hidden)
        .background(Color(.systemGroupedBackground))
        .toolbarBackground(.visible, for: .navigationBar)
        .task {
            await viewModel.selectCatalogItem(item)
        }
    }
}

private enum DetailAction: Equatable {
    case local
    case cloud
    case capture
    case magnet(String)
}
