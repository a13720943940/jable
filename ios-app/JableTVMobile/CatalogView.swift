import SwiftUI
import SwiftData
import Kingfisher

struct CatalogView: View {
    @EnvironmentObject private var viewModel: AppViewModel
    @Environment(\.modelContext) private var modelContext
    @Query private var catalogCaches: [CatalogPageCache]
    @State private var catalogFilter = "all"
    @AppStorage("catalogLayoutStyle") private var catalogLayoutStyle = "grid"
    private let gridColumns = [GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16)]

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
                        VStack(alignment: .leading, spacing: 14) {
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
                            .padding(12)
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
                            .frame(height: 34)

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
                                LazyVGrid(columns: gridColumns, spacing: 18) {
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
                        .padding(.horizontal, 16)
                        .padding(.top, 8)
                        .padding(.bottom, 16)
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
            .toolbar(.hidden, for: .navigationBar)
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
            poster(cornerRadius: 10)
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

    private func poster(cornerRadius: CGFloat) -> some View {
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
                .aspectRatio(16.0 / 9.0, contentMode: .fill)
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
        .frame(maxWidth: .infinity)
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
    @Environment(\.dismiss) private var dismiss
    let item: CatalogItem
    @State private var runningAction: DetailAction?

    var body: some View {
        ZStack {
            detailBackground
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    heroSection
                    actionSection
                    capturedSection
                    loadingSection
                    sampleSection
                    magnetSection
                }
                .frame(maxWidth: 430)
                .padding(.horizontal, 18)
                .padding(.top, 96)
                .padding(.bottom, 120)
                .frame(maxWidth: .infinity)
            }
        }
        .navigationTitle(detailCatalog)
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
        }
        .task {
            await viewModel.selectCatalogItem(item)
        }
    }

    private var detail: JableDetail? { viewModel.selectedJableDetail }
    private var detailTitle: String { detail?.title ?? item.title }
    private var detailCatalog: String {
        let catalog = detail?.catalog ?? item.catalog
        return catalog.isEmpty ? "影片详情" : catalog
    }
    private var coverURL: String {
        guard let detail, !detail.coverURL.isEmpty else { return item.imageURL }
        return detail.coverURL
    }

    private var detailBackground: some View {
        ZStack {
            KFImage(viewModel.client().proxiedImageURL(coverURL))
                .resizable()
                .scaledToFill()
                .ignoresSafeArea()
                .blur(radius: viewModel.isPrivacyModeEnabled ? 22 : 16)
                .opacity(0.46)
            LinearGradient(
                colors: [Color.black.opacity(0.18), Color(.systemBackground).opacity(0.62), Color(.systemBackground)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
        }
    }

    private var heroSection: some View {
        VStack(spacing: 16) {
            KFImage(viewModel.client().proxiedImageURL(coverURL))
                .placeholder {
                    ZStack {
                        RoundedRectangle(cornerRadius: 24).fill(.ultraThinMaterial)
                        Image(systemName: "film.stack")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                    }
                }
                .resizable()
                .scaledToFill()
                .frame(maxWidth: .infinity)
                .frame(height: 210)
                .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
                .shadow(color: .black.opacity(0.22), radius: 24, x: 0, y: 12)
                .blur(radius: viewModel.isPrivacyModeEnabled ? 12 : 0)

            VStack(spacing: 8) {
                Text(detailTitle)
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                Text("\(detailCatalog) · \(item.duration.isEmpty ? "时长未知" : item.duration)")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(item.detailURL)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var actionSection: some View {
        VStack(spacing: 12) {
            immersiveButton(title: "播放 / 抓取 M3U8", systemImage: "play.circle.fill", action: .capture) {
                await viewModel.captureSelectedMedia()
            }
            HStack(spacing: 12) {
                immersiveButton(title: "本地入库", systemImage: "arrow.down.circle.fill", action: .local) {
                    await viewModel.submitAutoTask(item)
                }
                immersiveButton(title: "离线 115", systemImage: "cloud.circle.fill", action: .cloud) {
                    await viewModel.submitSelectedToCloud()
                }
            }
        }
    }

    @ViewBuilder
    private var capturedSection: some View {
        if let captured = viewModel.capturedMedia {
            Button {
                viewModel.play(title: captured.title, url: URL(string: captured.mediaURL))
            } label: {
                HStack {
                    Label("在线播放", systemImage: "play.fill")
                    Spacer()
                    Image(systemName: "chevron.right")
                }
                .font(.headline)
                .padding(16)
                .background(.blue.opacity(0.16), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private var loadingSection: some View {
        if viewModel.isLoadingDetail {
            ProgressView("正在读取详情…")
                .frame(maxWidth: .infinity)
                .padding(24)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
    }

    @ViewBuilder
    private var sampleSection: some View {
        if let detail, !detail.samples.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("样张预览")
                    .font(.title3.bold())
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 12) {
                        ForEach(detail.samples, id: \.self) { sample in
                            KFImage(viewModel.client().proxiedImageURL(sample))
                                .placeholder {
                                    RoundedRectangle(cornerRadius: 18)
                                        .fill(.ultraThinMaterial)
                                        .overlay(Image(systemName: "photo"))
                                }
                                .resizable()
                                .scaledToFill()
                                .frame(width: 240, height: 150)
                                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                                .blur(radius: viewModel.isPrivacyModeEnabled ? 12 : 0)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .scrollIndicators(.hidden)
            }
        }
    }

    @ViewBuilder
    private var magnetSection: some View {
        if let detail {
            VStack(alignment: .leading, spacing: 12) {
                Text("磁力链接")
                    .font(.title3.bold())
                if detail.magnets.isEmpty {
                    ContentUnavailableView("暂无磁力链接", systemImage: "link.badge.plus")
                        .padding(18)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                } else {
                    ForEach(detail.magnets) { magnet in
                        magnetRow(magnet)
                    }
                }
            }
        }
    }

    private func immersiveButton(title: String, systemImage: String, action: DetailAction, operation: @escaping () async -> Void) -> some View {
        Button {
            Task {
                runningAction = action
                await operation()
                runningAction = nil
            }
        } label: {
            HStack {
                if runningAction == action {
                    ProgressView()
                } else {
                    Image(systemName: systemImage)
                }
                Text(title)
                    .font(.subheadline.bold())
            }
            .frame(maxWidth: .infinity)
            .frame(height: 48)
            .background(.white.opacity(0.92), in: Capsule())
            .foregroundStyle(.black.opacity(0.84))
        }
        .buttonStyle(.plain)
        .disabled(runningAction != nil)
    }

    private func magnetRow(_ magnet: MagnetItem) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(magnet.name.isEmpty ? "磁力链接" : magnet.name)
                .font(.headline)
                .lineLimit(2)
            HStack(spacing: 8) {
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
                Label("用此磁力离线到 115", systemImage: "cloud.fill")
                    .font(.subheadline.bold())
                    .frame(maxWidth: .infinity)
                    .frame(height: 42)
            }
            .buttonStyle(.borderedProminent)
            .disabled(runningAction != nil)
        }
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

private enum DetailAction: Equatable {
    case local
    case cloud
    case capture
    case magnet(String)
}
