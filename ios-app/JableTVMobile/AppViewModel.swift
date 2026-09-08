import Foundation
import SwiftUI

@MainActor
final class AppViewModel: ObservableObject {
    @Published var serverURL = ""
    @Published var accessPassword = ""
    @Published var catalogItems: [CatalogItem] = []
    @Published var catalogPage = 1
    @Published var catalogHasNext = false
    @Published var catalogPageSize = 24
    @Published var selectedCatalogItem: CatalogItem?
    @Published var selectedJableDetail: JableDetail?
    @Published var capturedMedia: CapturedMedia?
    @Published var localVideos: [LocalVideoItem] = []
    @Published var selectedLocalVideo: LocalVideoDetail?
    @Published var cloudTasks: [CloudTask] = []
    @Published var strmItems: [StrmItem] = []
    @Published var mediaFiles: [MediaFile] = []
    @Published var huangguoCatalogItems: [HuangguoCatalogItem] = []
    @Published var huangguoTabs: [HuangguoTab] = [HuangguoTab(id: "home", name: "首页")]
    @Published var huangguoCatalogPage = 1
    @Published var huangguoCatalogTab = "home"
    @Published var huangguoSearchText = ""
    @Published var huangguoSeries: [HuangguoSeries] = []
    @Published var selectedHuangguoSeries: HuangguoSeries?
    @Published var selectedHuangguoEpisodes: [HuangguoEpisode] = []
    @Published var selectedHuangguoOnline: HuangguoOnlineSeries?
    @Published var tasks: [DownloadTask] = []
    @Published var health: HealthStatus?
    @Published var license: LicenseInfo?
    @Published var heroStats: HeroStats?
    @Published var settings = AppSettings()
    @Published var isLoadingCatalog = false
    @Published var isLoadingDetail = false
    @Published var isLoadingMedia = false
    @Published var isLoadingTasks = false
    @Published var isLoadingHuangguo = false
    @Published var isSavingSettings = false
    @Published var isSubmittingAutoTask = false
    @Published var isChecking115Login = false
    @Published var check115Message = ""
    @Published var check115OK: Bool?
    @Published var searchText = ""
    @Published var mediaSearchText = ""
    @Published var taskSearchText = ""
    @Published var statusMessage = "准备就绪"
    @Published var selectedTab = 0
    @Published var playingTitle = ""
    @Published var playingURL: URL?

    @Published var manualURL = ""
    @Published var manualTitle = ""
    @Published var manualCatalog = ""
    @Published var manualPerformer = ""
    @Published var manualThreads = 2
    @Published var organizeEnabled = true
    @Published var allowDuplicate = false
    @Published var scrapePath = ""

    var isConfigured: Bool {
        !serverURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var isPrivacyModeEnabled: Bool {
        settings.privacyMode ?? true
    }

    var filteredCatalogItems: [CatalogItem] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return catalogItems }
        return catalogItems.filter {
            $0.title.lowercased().contains(query) ||
            $0.catalog.lowercased().contains(query)
        }
    }

    var filteredLocalVideos: [LocalVideoItem] {
        let query = mediaSearchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return localVideos }
        return localVideos.filter { $0.id.lowercased().contains(query) || $0.title.lowercased().contains(query) }
    }

    var filteredStrmItems: [StrmItem] {
        let query = mediaSearchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return strmItems }
        return strmItems.filter { $0.catalog.lowercased().contains(query) || $0.title.lowercased().contains(query) }
    }

    var filteredMediaFiles: [MediaFile] {
        let query = mediaSearchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return mediaFiles }
        return mediaFiles.filter { $0.name.lowercased().contains(query) || $0.path.lowercased().contains(query) }
    }

    var localLibrarySeries: [LocalLibrarySeries] {
        let huangguoGroups = Dictionary(grouping: mediaFiles.filter { $0.name.hasPrefix("黄果短剧/") }) { file in
            file.name.split(separator: "/").dropFirst().first.map(String.init) ?? "黄果短剧"
        }
        var entries = huangguoGroups.map { key, files in
            LocalLibrarySeries(
                id: "hg-local-\(key)",
                title: key,
                catalog: key,
                source: "黄果",
                coverPath: key,
                episodes: files.sorted { $0.name < $1.name }
            )
        }
        let normalFiles = mediaFiles.filter { !$0.name.hasPrefix("黄果短剧/") }
        entries += normalFiles.map { file in
            let catalog = file.name.replacingOccurrences(of: "\\.[^.]+$", with: "", options: .regularExpression)
            return LocalLibrarySeries(id: file.path, title: file.name, catalog: catalog, source: "本地", coverPath: "", episodes: [file])
        }
        let query = mediaSearchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let sorted = entries.sorted { lhs, rhs in lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending }
        guard !query.isEmpty else { return sorted }
        return sorted.filter { $0.title.lowercased().contains(query) || $0.catalog.lowercased().contains(query) }
    }

    var filteredTasks: [DownloadTask] {
        let query = taskSearchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return tasks }
        return tasks.filter { $0.catalog.lowercased().contains(query) || $0.title.lowercased().contains(query) || $0.phase.lowercased().contains(query) }
    }

    var filteredCloudTasks: [CloudTask] {
        let query = taskSearchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return cloudTasks }
        return cloudTasks.filter { $0.catalog.lowercased().contains(query) || $0.title.lowercased().contains(query) || $0.message.lowercased().contains(query) }
    }

    func configure(serverURL: String, accessPassword: String = "") {
        self.serverURL = normalized(serverURL)
        self.accessPassword = accessPassword
    }

    func client() -> APIClient {
        APIClient(baseURL: serverURL, accessPassword: accessPassword)
    }

    func refreshAll(refreshCatalog shouldRefreshCatalog: Bool = true) async {
        guard isConfigured else { return }
        await refreshHealth()
        await refreshStats()
        await refreshSettings()
        await refreshTasks()
        await refreshMedia()
        await refreshHuangguoSeries()
        if shouldRefreshCatalog {
            await refreshCatalog(page: catalogPage, force: false)
        }
    }

    func refreshHealth() async {
        do {
            health = try await client().health()
            statusMessage = "服务已连接"
        } catch {
            health = nil
            statusMessage = error.localizedDescription
        }
    }

    func refreshLicense() async {
        do {
            license = try await client().license()
        } catch {
            license = nil
        }
    }

    func verifyConnection() async -> Bool {
        await refreshHealth()
        if health != nil { return true }
        do {
            let response = try await client().catalog(page: 1, force: false)
            catalogPage = response.page
            catalogHasNext = response.hasNext
            catalogPageSize = response.pageSize
            catalogItems = response.items
            statusMessage = "服务已连接，已加载第 \(response.page) 页"
            return true
        } catch {
            statusMessage = error.localizedDescription
            return false
        }
    }

    func activateLicense(_ code: String) async {
        do {
            license = try await client().activateLicense(code: code)
            statusMessage = license?.message ?? "授权已激活"
            await refreshAll()
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func refreshStats() async {
        do {
            heroStats = try await client().heroStats()
        } catch {
            heroStats = nil
        }
    }

    func refreshSettings() async {
        do {
            settings = try await client().settings()
            manualThreads = settings.threads ?? manualThreads
            organizeEnabled = settings.organizeEnabled ?? organizeEnabled
            allowDuplicate = settings.allowDuplicate ?? allowDuplicate
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func refreshCatalog(page: Int? = nil, force: Bool) async {
        guard isConfigured else { return }
        isLoadingCatalog = true
        defer { isLoadingCatalog = false }
        do {
            let targetPage = max(1, page ?? catalogPage)
            let response = try await client().catalog(page: targetPage, force: force)
            catalogPage = response.page
            catalogHasNext = response.hasNext
            catalogPageSize = response.pageSize
            catalogItems = response.items
            statusMessage = "已加载第 \(response.page) 页，共 \(response.items.count) 部影片"
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func applyCachedCatalog(_ cache: CatalogPageCache) {
        guard let items = try? JSONDecoder().decode([CatalogItem].self, from: cache.payload) else { return }
        catalogPage = cache.page
        catalogHasNext = cache.hasNext
        catalogPageSize = cache.pageSize
        catalogItems = items
        statusMessage = "已显示缓存第 \(cache.page) 页，共 \(items.count) 部影片"
    }

    func catalogCachePayload() -> Data? {
        try? JSONEncoder().encode(catalogItems)
    }

    func nextCatalogPage() async {
        guard catalogHasNext else { return }
        await refreshCatalog(page: catalogPage + 1, force: false)
    }

    func previousCatalogPage() async {
        guard catalogPage > 1 else { return }
        await refreshCatalog(page: catalogPage - 1, force: false)
    }

    func selectCatalogItem(_ item: CatalogItem) async {
        selectedCatalogItem = item
        selectedJableDetail = nil
        capturedMedia = nil
        isLoadingDetail = true
        defer { isLoadingDetail = false }
        do {
            selectedJableDetail = try await client().jableDetail(detailURL: item.detailURL, duration: item.duration)
            statusMessage = "详情已加载"
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func captureSelectedMedia() async {
        guard let item = selectedCatalogItem else { return }
        isSubmittingAutoTask = true
        defer { isSubmittingAutoTask = false }
        do {
            capturedMedia = try await client().capture(detailURL: item.detailURL)
            statusMessage = "已获取播放地址"
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func submitSelectedToCloud(sourceURL: String? = nil) async {
        guard let item = selectedCatalogItem else { return }
        isSubmittingAutoTask = true
        defer { isSubmittingAutoTask = false }
        do {
            if let sourceURL, !sourceURL.isEmpty {
                _ = try await client().createCloudTask(
                    sourceURL: sourceURL,
                    title: selectedJableDetail?.title ?? item.title,
                    catalog: selectedJableDetail?.catalog ?? item.catalog,
                    detailURL: item.detailURL
                )
            } else {
                _ = try await client().autoCloudTask(item: item)
            }
            statusMessage = "已提交到 115 离线"
            selectedTab = 2
            await refreshCloudAfterSubmit()
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func refreshMedia() async {
        guard isConfigured else { return }
        isLoadingMedia = true
        defer { isLoadingMedia = false }
        var loadedCount = 0
        do {
            strmItems = try await client().strmLibrary()
            loadedCount += strmItems.count
        } catch {
            strmItems = []
            statusMessage = error.localizedDescription
        }
        do {
            mediaFiles = try await client().mediaFiles()
            loadedCount += mediaFiles.count
        } catch {
            mediaFiles = []
            statusMessage = error.localizedDescription
        }
        localVideos = []
        if loadedCount > 0 {
            statusMessage = "媒体库已加载 \(loadedCount) 项"
        }
    }

    func refreshHuangguoCatalog(tab: String? = nil, page: Int? = nil, force: Bool = false) async {
        guard isConfigured else { return }
        isLoadingHuangguo = true
        defer { isLoadingHuangguo = false }
        do {
            let nextTab = tab ?? huangguoCatalogTab
            let nextPage = max(1, page ?? huangguoCatalogPage)
            let response = try await client().huangguoCatalog(tab: nextTab, page: nextPage, keyword: huangguoSearchText, force: force)
            huangguoCatalogItems = response.items
            huangguoTabs = response.tabs.isEmpty ? huangguoTabs : response.tabs
            huangguoCatalogTab = nextTab
            huangguoCatalogPage = response.page
            statusMessage = "黄果第 \(response.page) 页已加载 \(response.items.count) 部"
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func refreshHuangguoSeries() async {
        guard isConfigured else { return }
        do {
            huangguoSeries = try await client().huangguoSeries()
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func loadHuangguoEpisodes(_ series: HuangguoSeries) async {
        selectedHuangguoSeries = series
        do {
            selectedHuangguoEpisodes = try await client().huangguoEpisodes(seriesID: series.id)
            statusMessage = "已加载 \(series.title) 分集"
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func loadHuangguoOnline(detailURL: String) async {
        isLoadingHuangguo = true
        defer { isLoadingHuangguo = false }
        do {
            selectedHuangguoOnline = try await client().huangguoOnlineEpisodes(detailURL: detailURL)
            statusMessage = "已解析在线播放分集"
        } catch {
            selectedHuangguoOnline = nil
            statusMessage = error.localizedDescription
        }
    }

    func addHuangguoSeries(url: String) async {
        do {
            let response = try await client().huangguoCreateSeries(url: url)
            huangguoSeries.removeAll { $0.id == response.series.id }
            huangguoSeries.insert(response.series, at: 0)
            selectedHuangguoSeries = response.series
            selectedHuangguoEpisodes = response.episodes
            statusMessage = response.existed == true ? "短剧已在追剧库，已刷新" : "短剧已入库，自动下载 \(response.queued ?? 0) 集"
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func runHuangguoAction(_ action: HuangguoAction) async {
        do {
            switch action {
            case .check(let seriesID):
                _ = try await client().huangguoCheck(seriesID: seriesID)
                statusMessage = "已检查追更"
            case .rescrape(let seriesID):
                let reply = try await client().huangguoRescrape(seriesID: seriesID)
                statusMessage = "重新刮削完成，入队 \(reply.queued ?? 0) 集"
            case .downloadMissing(let seriesID):
                let reply = try await client().huangguoDownloadMissing(seriesID: seriesID)
                statusMessage = "缺失集已入队 \(reply.queued ?? 0) 集"
            case .downloadEpisode(let episodeID):
                _ = try await client().huangguoDownloadEpisode(episodeID: episodeID)
                statusMessage = "分集已加入下载队列"
            case .retryUpload(let episodeID):
                _ = try await client().huangguoRetryUpload(episodeID: episodeID)
                statusMessage = "已加入上传重试"
            case .retryFailedAll:
                let reply = try await client().huangguoRetryFailedAll()
                statusMessage = "失败集已重试 \(reply.queued ?? 0) 集"
            case .downloadMissingAll:
                let reply = try await client().huangguoDownloadMissingAll()
                statusMessage = "全部缺失已入队 \(reply.queued ?? 0) 集"
            case .complete(let seriesID, let completed):
                let reply = try await client().huangguoSetCompleted(seriesID: seriesID, completed: completed)
                statusMessage = completed ? "已标记完结，上传队列 \(reply.queued ?? 0) 集" : "已恢复追更"
            case .delete(let seriesID, let deleteFiles):
                _ = try await client().huangguoDeleteSeries(seriesID: seriesID, deleteFiles: deleteFiles)
                selectedHuangguoSeries = nil
                selectedHuangguoEpisodes = []
                statusMessage = "短剧已删除"
            case .scanAll:
                _ = try await client().huangguoScanAll()
                statusMessage = "全库扫描已启动"
            case .stopScan:
                _ = try await client().huangguoStopScanAll()
                statusMessage = "已发送停止扫描指令"
            }
            await refreshHuangguoSeries()
            if let selectedHuangguoSeries {
                await loadHuangguoEpisodes(selectedHuangguoSeries)
            }
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func refreshTasks() async {
        guard isConfigured else { return }
        isLoadingTasks = true
        defer { isLoadingTasks = false }
        do {
            async let local = client().tasks()
            async let cloud = client().cloudTasks()
            tasks = try await local
            cloudTasks = try await cloud
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func submitAutoTask(_ item: CatalogItem) async {
        isSubmittingAutoTask = true
        defer { isSubmittingAutoTask = false }
        do {
            _ = try await client().autoTask(
                detailURL: item.detailURL,
                threads: manualThreads,
                organizeEnabled: organizeEnabled,
                allowDuplicate: allowDuplicate
            )
            statusMessage = "\(item.catalog.isEmpty ? item.title : item.catalog) 已加入队列"
            selectedTab = 2
            await refreshTasks()
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func submitManualTask() async {
        do {
            try await client().createTask(
                url: manualURL,
                title: manualTitle,
                catalog: manualCatalog,
                performer: manualPerformer,
                threads: manualThreads,
                organizeEnabled: organizeEnabled,
                allowDuplicate: allowDuplicate
            )
            statusMessage = "手动任务已加入队列"
            manualURL = ""
            manualTitle = ""
            manualCatalog = ""
            manualPerformer = ""
            selectedTab = 2
            await refreshTasks()
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func submitManualScrape() async {
        do {
            _ = try await client().manualScrape(path: scrapePath, title: manualTitle, catalog: manualCatalog, performer: manualPerformer)
            statusMessage = "手动刮削已加入队列"
            scrapePath = ""
            selectedTab = 2
            await refreshTasks()
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func retry(_ task: DownloadTask) async {
        do {
            _ = try await client().retry(taskID: task.id)
            statusMessage = "已加入重试队列"
            await refreshTasks()
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func deleteCloudTask(_ task: CloudTask) async {
        do {
            _ = try await client().deleteCloudTask(id: task.id)
            statusMessage = "115 任务已删除"
            await refreshTasks()
            await refreshMedia()
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func deleteStrmItem(_ item: StrmItem) async {
        do {
            _ = try await client().deleteStrmItem(id: item.id)
            statusMessage = "媒体库条目已删除"
            await refreshMedia()
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func saveSettings() async {
        isSavingSettings = true
        defer { isSavingSettings = false }
        do {
            settings = try await client().saveSettings(settings)
            statusMessage = "设置已保存"
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func check115Login() async {
        isChecking115Login = true
        check115OK = nil
        check115Message = ""
        defer { isChecking115Login = false }
        do {
            let result = try await client().check115Login()
            check115OK = result.ok
            check115Message = result.message
            statusMessage = result.message
        } catch {
            check115OK = false
            check115Message = error.localizedDescription
            statusMessage = error.localizedDescription
        }
    }

    private func refreshCloudAfterSubmit() async {
        await refreshTasks()
        _ = try? await client().pollCloudTasksNow()
        await refreshTasks()
        await refreshMedia()
        await refreshStats()
        try? await Task.sleep(for: .seconds(3))
        _ = try? await client().pollCloudTasksNow()
        await refreshTasks()
        await refreshMedia()
        await refreshStats()
    }

    func play(title: String, url: URL?) {
        guard let url else {
            statusMessage = "没有可播放地址"
            return
        }
        playingTitle = title
        playingURL = url
    }

    func normalized(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if !value.isEmpty, !value.hasPrefix("http://"), !value.hasPrefix("https://") {
            value = "http://" + value
        }
        return value.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}

enum HuangguoAction {
    case check(String)
    case rescrape(String)
    case downloadMissing(String)
    case downloadEpisode(String)
    case retryUpload(String)
    case retryFailedAll
    case downloadMissingAll
    case complete(String, Bool)
    case delete(String, Bool)
    case scanAll
    case stopScan
}
