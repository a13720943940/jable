import AppKit
import Foundation
import UniformTypeIdentifiers
import WebKit

enum TaskListFilter: String, CaseIterable, Identifiable {
    case all = "全部"
    case pending = "等待"
    case running = "进行中"
    case completed = "已完成"
    case failed = "失败"
    case scrapeFailed = "刮削失败"

    var id: String { rawValue }
}

@MainActor
final class QueueDownloadViewModel: ObservableObject {
    @Published var inputURL = ""
    @Published var saveDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Downloads/N_m3u8DL-RE").path
    @Published var saveName = ""
    @Published var extraArgs = ""
    @Published var catalogNumber = ""
    @Published var performerName = ""
    @Published var scraperDomain = "www.javbus.com"
    @Published var scraperSources: [ScraperSource] = []
    @Published var previewBeforeCompletion = false
    @Published var showingSourceManager = false
    @Published var showingJableCatalog = false
    @Published var newScraperDomain = ""
    @Published var organizeAfterDownload = true
    @Published var selectedHistoryFile = ""

    @Published var autoDetectClipboard = true
    @Published var autoFillBrowserTitle = true
    @Published var clipboardStatus = "复制媒体链接后会自动填入"

    @Published var downloadThreadCount = 2
    @Published var allowDuplicateDownload = false
    @Published var nasEnabled = false
    @Published var nasServerURL = "smb://"
    @Published var nasDestinationPath = ""
    @Published var nasScrapeFailureEnabled = false
    @Published var nasScrapeFailurePath = ""
    @Published var nasMoveAfterTransfer = false

    @Published var tasks: [DownloadQueueItem] = []
    @Published var selectedTaskID: UUID?
    @Published var logText = "已就绪。"
    @Published var statusText = "空闲"
    @Published var progressValue: Double = 0
    @Published var progressKnown = false
    @Published var progressText = "等待任务"
    @Published var segmentText = "未开始"
    @Published var speedText = "-"
    @Published var etaText = "-"
    @Published var isRunning = false
    @Published var isOrganizing = false
    @Published var isPreparingNAS = false
    @Published var nasConnectionStatus = "未检查"
    @Published var taskFilter: TaskListFilter = .all
    @Published var showingScrapePreview = false
    @Published var previewTaskID: UUID?
    @Published var previewTitle = ""
    @Published var previewPerformer = ""
    @Published var previewReleaseDate = ""
    @Published var previewDescription = ""
    @Published var previewKeywords = ""
    @Published var previewCoverPath = ""
    @Published var taskAddedNotice = ""
    @Published var showingTaskAddedNotice = false
    @Published var isRefreshingAutoCapture = false

    var isBusy: Bool { isRunning || isOrganizing || isPreparingNAS || isRefreshingAutoCapture }
    var pendingCount: Int { tasks.filter { $0.state == .pending }.count }
    var filteredTasks: [DownloadQueueItem] {
        tasks.filter { task in
            switch taskFilter {
            case .all: return true
            case .pending: return task.state == .pending
            case .running: return !task.state.isFinished && task.state != .pending && task.state != .awaitingReview
            case .completed: return task.state == .completed
            case .failed: return [.failed, .cancelled, .interrupted].contains(task.state)
            case .scrapeFailed: return task.scrapeStepResult == .failed
            }
        }
        .sorted { $0.createdAt > $1.createdAt }
    }
    var completedTaskCount: Int { tasks.filter { $0.state == .completed }.count }
    var failedTaskCount: Int { tasks.filter { [.failed, .cancelled, .interrupted].contains($0.state) }.count }
    var scrapeFailedTaskCount: Int { tasks.filter { $0.scrapeStepResult == .failed }.count }
    var totalCompletedBytes: Int64 {
        tasks.filter { $0.state == .completed }.reduce(0) { $0 + ($1.totalBytes ?? $1.downloadedBytes ?? 0) }
    }
    var enabledScraperDomains: [String] {
        let domains = scraperSources.filter(\.enabled).map(\.domain)
        return domains.isEmpty ? [scraperDomain] : domains
    }

    private var store: QueueStore?
    private var process: Process?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private var activeTaskID: UUID?
    private var runStartDate: Date?
    private var lastPersistDate = Date.distantPast
    private var lastPasteboardChangeCount = NSPasteboard.general.changeCount
    private var lastBrowserBundleIdentifier: String?
    private var pendingSourcePageURL = ""

    init() {
        do {
            let store = try QueueStore()
            self.store = store
            let settings = store.loadSettings()
            downloadThreadCount = settings.downloadThreadCount
            allowDuplicateDownload = settings.allowDuplicateDownload ?? false
            previewBeforeCompletion = false
            scraperSources = settings.scraperSources ?? Self.defaultScraperSources
            scraperSources = scraperSources.map { source in
                var reset = source
                if reset.health == .checking { reset.health = .unchecked }
                return reset
            }
            if let primary = scraperSources.first(where: { $0.enabled })?.domain { scraperDomain = primary }
            nasEnabled = settings.nasEnabled
            nasServerURL = settings.nasServerURL
            nasDestinationPath = settings.nasDestinationPath
            nasScrapeFailurePath = settings.nasScrapeFailurePath ?? ""
            nasScrapeFailureEnabled = settings.nasScrapeFailureEnabled ?? !nasScrapeFailurePath.isEmpty
            nasMoveAfterTransfer = settings.nasMoveAfterTransfer
            tasks = try store.loadTasks().map { item in
                var recovered = Self.migrateStepResults(item)
                recovered.previewBeforeCompletion = false
                if [.checkingNAS, .parsing, .downloading, .merging, .scraping, .organizing, .nasTransferring].contains(item.state) {
                    switch item.state {
                    case .checkingNAS:
                        recovered.downloadStepResult = .skipped
                        recovered.scrapeStepResult = .skipped
                        recovered.nasStepResult = .failed
                    case .parsing, .downloading, .merging:
                        recovered.downloadStepResult = .failed
                        recovered.scrapeStepResult = .skipped
                        recovered.nasStepResult = .skipped
                    case .scraping, .organizing:
                        recovered.downloadStepResult = .succeeded
                        recovered.scrapeStepResult = .failed
                        recovered.nasStepResult = .skipped
                    case .nasTransferring:
                        recovered.nasStepResult = .failed
                    case .awaitingReview, .pending, .completed, .skipped, .failed, .cancelled, .interrupted:
                        break
                    }
                    recovered.state = .interrupted
                    recovered.phase = "上次运行被中断"
                    recovered.resultMessage = "App 退出或系统重启导致任务中断，可点击重试。"
                    recovered.finishedAt = Date()
                    try? store.saveTask(recovered)
                }
                if recovered != item { try? store.saveTask(recovered) }
                return recovered
            }
        } catch {
            logText = "任务数据库初始化失败：\(error.localizedDescription)"
            statusText = "数据库异常"
        }
        DispatchQueue.main.async { [weak self] in
            self?.resumeLegacyPreviewTasksIfNeeded()
        }
    }

    private static let defaultScraperSources = [
        ScraperSource(id: UUID(), domain: "www.javbus.com", enabled: true, health: .unchecked),
        ScraperSource(id: UUID(), domain: "www.busdmm.ink", enabled: true, health: .unchecked),
        ScraperSource(id: UUID(), domain: "www.dmmsee.bond", enabled: true, health: .unchecked)
    ]

    private static func migrateStepResults(_ item: DownloadQueueItem) -> DownloadQueueItem {
        var migrated = item
        if migrated.downloadStepResult == nil {
            switch item.state {
            case .pending, .checkingNAS: migrated.downloadStepResult = .pending
            case .parsing, .downloading, .merging: migrated.downloadStepResult = .running
            case .skipped: migrated.downloadStepResult = .skipped
            case .scraping, .organizing, .awaitingReview, .nasTransferring, .completed: migrated.downloadStepResult = .succeeded
            case .failed, .cancelled, .interrupted:
                migrated.downloadStepResult = item.outputPath.isEmpty ? .failed : .succeeded
            }
        }
        if migrated.scrapeStepResult == nil {
            if !item.organizeAfterDownload {
                migrated.scrapeStepResult = .skipped
            } else if item.resultMessage.contains("刮削未匹配") || item.resultMessage.contains("刮削整理失败") {
                migrated.scrapeStepResult = .failed
            } else {
                switch item.state {
                case .scraping, .organizing: migrated.scrapeStepResult = .running
                case .awaitingReview, .nasTransferring, .completed: migrated.scrapeStepResult = .succeeded
                default: migrated.scrapeStepResult = .pending
                }
            }
        }
        if migrated.nasStepResult == nil {
            if !item.nasEnabled {
                migrated.nasStepResult = .skipped
            } else if item.resultMessage.contains("NAS 发送失败") || item.resultMessage.contains("NAS 自动重连失败") {
                migrated.nasStepResult = .failed
            } else if item.state == .nasTransferring {
                migrated.nasStepResult = .running
            } else if item.state == .completed && (item.resultMessage.contains("NAS") || item.resultMessage.contains("已发送")) {
                migrated.nasStepResult = .succeeded
            } else {
                migrated.nasStepResult = .pending
            }
        }
        return migrated
    }

    func addTask() {
        let trimmedInput = inputURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedInput.isEmpty else {
            appendDisplayLog("请输入下载地址后再加入队列。")
            return
        }
        if catalogNumber.isEmpty { detectCatalogNumberFromTitle() }
        if tasks.contains(where: {
            !$0.state.isFinished && ($0.inputURL == trimmedInput || (!catalogNumber.isEmpty && $0.catalogNumber == catalogNumber))
        }) {
            appendDisplayLog("队列中已存在相同链接或番号，已取消重复添加。")
            return
        }
        if !allowDuplicateDownload,
           let reason = duplicateReason(
               inputURL: trimmedInput,
               saveDirectory: saveDirectory,
               catalogNumber: catalogNumber,
               saveName: saveName
           ) {
            appendDisplayLog("检测到已经下载：\(reason)\n如需重新下载，请开启“允许重复下载”。")
            statusText = "检测到重复"
            return
        }
        if nasEnabled && nasDestinationPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            appendDisplayLog("已启用 NAS，但尚未选择 NAS 目标路径。")
            return
        }
        if nasEnabled && nasScrapeFailureEnabled
            && nasScrapeFailurePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            appendDisplayLog("已开启刮削失败发送，但尚未选择刮削失败路径。")
            return
        }

        let task = DownloadQueueItem(
            id: UUID(),
            inputURL: trimmedInput,
            saveDirectory: saveDirectory,
            saveName: saveName.trimmingCharacters(in: .whitespacesAndNewlines),
            sourcePageURL: pendingSourcePageURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : pendingSourcePageURL,
            extraArgs: extraArgs,
            catalogNumber: catalogNumber.trimmingCharacters(in: .whitespacesAndNewlines),
            performerName: performerName.trimmingCharacters(in: .whitespacesAndNewlines),
            scraperDomain: scraperDomain.trimmingCharacters(in: .whitespacesAndNewlines),
            scraperDomains: enabledScraperDomains,
            previewBeforeCompletion: false,
            organizeAfterDownload: organizeAfterDownload,
            threadCount: min(max(downloadThreadCount, 1), 16),
            allowDuplicateDownload: allowDuplicateDownload,
            nasEnabled: nasEnabled,
            nasServerURL: nasServerURL,
            nasDestinationPath: nasDestinationPath,
            nasScrapeFailureEnabled: nasScrapeFailureEnabled,
            nasScrapeFailurePath: nasScrapeFailurePath,
            nasLastTransferPath: nil,
            nasMoveAfterTransfer: nasMoveAfterTransfer,
            downloadStepResult: .pending,
            scrapeStepResult: organizeAfterDownload ? .pending : .skipped,
            nasStepResult: nasEnabled ? .pending : .skipped,
            downloadedBytes: nil,
            totalBytes: nil,
            scrapeMetadataFound: nil,
            reviewFolderPath: nil,
            state: .pending,
            progress: 0,
            phase: "等待执行",
            resultMessage: "",
            outputPath: "",
            logText: "任务已加入队列。",
            createdAt: Date(),
            startedAt: nil,
            finishedAt: nil
        )
        tasks.insert(task, at: 0)
        selectedTaskID = task.id
        logText = task.logText
        persist(task)
        saveSettings()
        clearDraftAfterAdding()
        startNextTaskIfPossible()
    }

    func startDownload() {
        addTask()
    }

    func addCapturedJableTask(mediaURL: String, title: String, pageURL: String) {
        inputURL = mediaURL
        saveName = sanitizedFileName(title)
        pendingSourcePageURL = pageURL
        catalogNumber = MediaOrganizer.catalogNumber(from: pageURL)
            ?? MediaOrganizer.catalogNumber(from: title)
            ?? ""
        clipboardStatus = "自动影片库已捕获标题、番号和 M3U8"
        appendDisplayLog("自动影片库已捕获 \(catalogNumber.isEmpty ? title : catalogNumber)，正在立即创建并启动任务。")
        addTask()
        if let taskID = selectedTaskID {
            moveTaskToFront(taskID)
        }
        showTaskAddedNotice("添加成功", subtitle: "\(catalogNumber.isEmpty ? title : catalogNumber) 已加入队列")
    }

    func showTaskAddedNotice(_ title: String, subtitle: String) {
        taskAddedNotice = "\(title)\n\(subtitle)"
        showingTaskAddedNotice = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            guard let self else { return }
            if self.taskAddedNotice == "\(title)\n\(subtitle)" {
                self.showingTaskAddedNotice = false
            }
        }
    }

    func stopDownload() {
        guard let activeTaskID else { return }
        process?.terminate()
        updateTask(activeTaskID, persist: true) { task in
            if [.parsing, .downloading, .merging].contains(task.state) {
                task.downloadStepResult = .failed
            }
            task.state = .cancelled
            task.phase = "用户取消"
            task.resultMessage = "任务已由用户取消。"
            task.finishedAt = Date()
        }
        appendTaskLog(activeTaskID, "任务已由用户取消。")
    }

    func retryTask(_ id: UUID) {
        guard !isActiveTask(id) else { return }
        if let task = tasks.first(where: { $0.id == id }),
           task.state == .failed,
           task.nasEnabled,
           task.resultMessage.contains("NAS 发送失败"),
           !task.outputPath.isEmpty,
           FileManager.default.fileExists(atPath: task.outputPath) {
            retryNASTransfer(task)
            return
        }
        updateTask(id, persist: true) { task in
            task.state = .pending
            task.progress = 0
            task.phase = "等待重试"
            task.resultMessage = ""
            task.finishedAt = nil
            task.downloadStepResult = .pending
            task.scrapeStepResult = task.organizeAfterDownload ? .pending : .skipped
            task.nasStepResult = task.nasEnabled ? .pending : .skipped
            task.downloadedBytes = nil
            task.totalBytes = nil
            task.scrapeMetadataFound = nil
            task.reviewFolderPath = nil
        }
        startNextTaskIfPossible()
    }

    func retryScraping(_ id: UUID, useCurrentSource: Bool) {
        guard !isBusy,
              let task = tasks.first(where: { $0.id == id }),
              task.resultMessage.contains("刮削未匹配") else { return }
        guard let sourceFile = mediaFile(for: task) else {
            appendDisplayLog("无法找到可重新刮削的本地或 NAS 视频文件。")
            return
        }

        let selectedDomain = useCurrentSource
            ? scraperDomain.trimmingCharacters(in: .whitespacesAndNewlines)
            : task.scraperDomain
        isOrganizing = true
        selectedTaskID = id
        statusText = "重新刮削"
        updateTask(id, persist: true) { item in
            item.state = .scraping
            item.phase = useCurrentSource ? "使用当前元数据源重试" : "使用原元数据源重试"
            item.progress = 0
            item.scrapeStepResult = .running
            if useCurrentSource { item.scraperDomain = selectedDomain }
        }
        appendTaskLog(id, "重新刮削，元数据源：\(selectedDomain)")

        Task {
            do {
                let result = try await MediaOrganizer.organize(
                    saveDirectory: task.saveDirectory,
                    requestedName: task.saveName,
                    explicitCatalogNumber: task.catalogNumber,
                    explicitPerformerName: task.performerName == "未知演员" ? "" : task.performerName,
                    startedAt: .distantPast,
                    scraperDomains: useCurrentSource
                        ? enabledScraperDomains
                        : (task.scraperDomains ?? organizationDomains(selectedDomain)),
                    sourceFile: sourceFile
                ) { [weak self] value, phase in
                    self?.progressKnown = true
                    self?.progressValue = value
                    self?.progressText = phase
                    self?.updateTask(id) { item in
                        item.progress = value
                        item.phase = phase
                    }
                }

                guard result.metadataFound else {
                    appendTaskLog(id, "重新刮削仍未匹配到在线元数据。")
                    updateTask(id, persist: true) { item in
                        item.state = .completed
                        item.progress = 1
                        item.phase = "完成（刮削未匹配）"
                        item.scrapeStepResult = .failed
                        item.resultMessage = "重新刮削仍未匹配；文件已保留，可换源后再次重试。"
                        item.outputPath = result.mediaURL.path
                        item.reviewFolderPath = result.folderURL.path
                        item.scrapeMetadataFound = false
                        item.finishedAt = Date()
                    }
                    statusText = "刮削未匹配"
                    isOrganizing = false
                    startNextTaskIfPossible()
                    return
                }

                var outputPath = result.mediaURL.path
                if task.nasEnabled {
                    let normalDestination = nasDestinationPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? task.nasDestinationPath
                        : nasDestinationPath
                    let transfer = try await sendToNAS(
                        localFolder: result.folderURL,
                        performer: result.performerName,
                        catalog: result.folderURL.lastPathComponent,
                        serverURL: task.nasServerURL ?? nasServerURL,
                        destinationPath: normalDestination,
                        moveAfterTransfer: task.nasMoveAfterTransfer,
                        taskID: id
                    )
                    if task.nasMoveAfterTransfer { outputPath = transfer.destinationURL.path }
                    appendTaskLog(id, "重新刮削成功并发送到正常 NAS 路径：\(transfer.destinationURL.path)")
                } else {
                    appendTaskLog(id, "重新刮削成功：\(result.mediaURL.path)")
                }
                updateTask(id, persist: true) { item in
                    item.state = .completed
                    item.progress = 1
                    item.phase = "重新刮削完成"
                    item.scrapeStepResult = .succeeded
                    if task.nasEnabled { item.nasStepResult = .succeeded }
                    item.resultMessage = task.nasEnabled ? "重新刮削成功，已发送到正常 NAS 路径。" : "重新刮削成功。"
                    item.catalogNumber = result.folderURL.lastPathComponent
                    item.performerName = result.performerName
                    item.outputPath = outputPath
                    item.finishedAt = Date()
                }
                statusText = "重新刮削完成"
            } catch {
                failTask(id, message: "重新刮削失败：\(error.localizedDescription)")
            }
            isOrganizing = false
            startNextTaskIfPossible()
        }
    }

    private func retryNASTransfer(_ task: DownloadQueueItem) {
        guard !isBusy else { return }
        isOrganizing = true
        selectedTaskID = task.id
        Task {
            do {
                let localFolder = URL(fileURLWithPath: task.outputPath).deletingLastPathComponent()
                let result = try await sendToNAS(
                    localFolder: localFolder,
                    performer: task.performerName.isEmpty ? "未知演员" : task.performerName,
                    catalog: task.catalogNumber,
                    serverURL: task.nasServerURL ?? nasServerURL,
                    destinationPath: task.nasLastTransferPath ?? task.nasDestinationPath,
                    moveAfterTransfer: task.nasMoveAfterTransfer,
                    taskID: task.id
                )
                appendTaskLog(task.id, "NAS 重试成功：\(result.destinationURL.path)")
                updateTask(task.id, persist: true) { item in
                    item.state = .completed
                    item.progress = 1
                    item.phase = "全部步骤完成"
                    item.nasStepResult = .succeeded
                    item.resultMessage = "NAS 重试发送成功。"
                    if item.nasMoveAfterTransfer { item.outputPath = result.destinationURL.path }
                    item.finishedAt = Date()
                }
            } catch {
                failTask(task.id, message: "NAS 发送失败：\(error.localizedDescription)")
            }
            isOrganizing = false
            startNextTaskIfPossible()
        }
    }

    func cancelPendingTask(_ id: UUID) {
        if isActiveTask(id) {
            stopDownload()
            return
        }
        updateTask(id, persist: true) { task in
            task.downloadStepResult = .skipped
            task.scrapeStepResult = .skipped
            task.nasStepResult = .skipped
            task.state = .cancelled
            task.phase = "已取消"
            task.finishedAt = Date()
        }
    }

    func deleteTask(_ id: UUID) {
        guard !isActiveTask(id) else { return }
        tasks.removeAll { $0.id == id }
        try? store?.deleteTask(id: id)
        if selectedTaskID == id {
            selectedTaskID = nil
            logText = "请选择任务查看日志。"
        }
    }

    func moveTaskToFront(_ id: UUID) {
        guard let index = tasks.firstIndex(where: { $0.id == id }), tasks[index].state == .pending else { return }
        let task = tasks.remove(at: index)
        let insertionIndex = tasks.firstIndex(where: { $0.state == .pending }) ?? tasks.endIndex
        tasks.insert(task, at: insertionIndex)
        persistAllTasks()
    }

    func selectTask(_ id: UUID) {
        selectedTaskID = id
        if let task = tasks.first(where: { $0.id == id }) {
            logText = task.logText
        }
    }

    func canPreviewScrapeResult(_ task: DownloadQueueItem) -> Bool {
        guard task.organizeAfterDownload, task.scrapeStepResult != .pending else { return false }
        return scrapeFolder(for: task) != nil
    }

    func scrapeCoverPath(for task: DownloadQueueItem) -> String {
        guard let folder = scrapeFolder(for: task) else { return "" }
        let catalog = task.catalogNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        let preferredNames = ["\(catalog)-poster.jpg", "\(catalog)-fanart.jpg"]
        for name in preferredNames where !catalog.isEmpty {
            let candidate = folder.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate.path }
        }
        let imageExtensions = Set(["jpg", "jpeg", "png", "webp"])
        let images = (try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        return images
            .filter { imageExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .first?.path ?? ""
    }

    func openScrapePreview(_ id: UUID) {
        guard let task = tasks.first(where: { $0.id == id }),
              let folder = scrapeFolder(for: task),
              let metadata = try? MediaOrganizer.loadMetadata(from: folder) else {
            appendDisplayLog("找不到该任务的刮削元数据文件。")
            return
        }
        previewTaskID = id
        previewTitle = metadata.title
        previewPerformer = task.performerName == "未知演员"
            ? (metadata.actress.keys.sorted().first ?? "未知演员")
            : task.performerName
        previewReleaseDate = metadata.releaseDate
        previewDescription = metadata.description
        previewKeywords = metadata.keywords.joined(separator: ", ")
        let poster = folder.appendingPathComponent("\(task.catalogNumber)-poster.jpg")
        let fanart = folder.appendingPathComponent("\(task.catalogNumber)-fanart.jpg")
        previewCoverPath = FileManager.default.fileExists(atPath: poster.path) ? poster.path : fanart.path
        showingScrapePreview = true
    }

    func confirmScrapePreview() {
        guard !isBusy,
              let id = previewTaskID,
              let task = tasks.first(where: { $0.id == id }),
              let folder = scrapeFolder(for: task) else { return }
        showingScrapePreview = false
        isOrganizing = true
        statusText = "应用刮削结果"
        Task {
            do {
                let edited = try MediaOrganizer.applyMetadataEdits(
                    folderURL: folder,
                    title: previewTitle,
                    performerName: previewPerformer,
                    releaseDate: previewReleaseDate,
                    description: previewDescription,
                    keywords: previewKeywords
                        .split(separator: ",")
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty }
                )
                updateTask(id, persist: true) { item in
                    item.performerName = previewPerformer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? "未知演员" : previewPerformer.trimmingCharacters(in: .whitespacesAndNewlines)
                    item.outputPath = edited.mediaURL.path
                    item.reviewFolderPath = edited.folderURL.path
                    item.state = .organizing
                    item.phase = "预览已确认"
                }
                appendTaskLog(id, "刮削预览已确认，继续后续步骤。")
                await finishPostProcessing(
                    taskID: id,
                    metadataFound: task.scrapeMetadataFound ?? false,
                    localFolder: edited.folderURL
                )
            } catch {
                failTask(id, message: "应用刮削预览修改失败：\(error.localizedDescription)")
            }
            isOrganizing = false
            startNextTaskIfPossible()
        }
    }

    func retryPreviewWithCurrentSources() {
        guard let id = previewTaskID else { return }
        showingScrapePreview = false
        retryScraping(id, useCurrentSource: true)
    }

    private func scrapeFolder(for task: DownloadQueueItem) -> URL? {
        let paths = [task.reviewFolderPath, Optional(task.outputPath)].compactMap { $0 }
        let candidates = paths.compactMap { path -> URL? in
            guard !path.isEmpty else { return nil }
            let url = URL(fileURLWithPath: path)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return nil }
            return isDirectory.boolValue ? url : url.deletingLastPathComponent()
        }
        return candidates.first { FileManager.default.fileExists(atPath: $0.appendingPathComponent("metadata.json").path) }
    }

    func openTaskOutput(_ id: UUID) {
        guard let task = tasks.first(where: { $0.id == id }), !task.outputPath.isEmpty else { return }
        let url = URL(fileURLWithPath: task.outputPath)
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    func connectNAS() {
        let value = nasServerURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: value), url.scheme?.lowercased() == "smb" else {
            appendDisplayLog("请输入有效的 SMB 地址，例如 smb://192.168.1.10/Media。")
            return
        }
        NSWorkspace.shared.open(url)
        appendDisplayLog("已请求连接 NAS，请在 Finder 登录窗口中完成验证。")
        saveSettings()
    }

    func browseNASDestination() {
        browseNASPath(currentPath: nasDestinationPath) { [weak self] path in
            self?.nasDestinationPath = path
        }
    }

    func browseNASScrapeFailureDestination() {
        browseNASPath(currentPath: nasScrapeFailurePath) { [weak self] path in
            self?.nasScrapeFailurePath = path
        }
    }

    private func browseNASPath(currentPath: String, update: (String) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "选择 NAS 目录"
        if !currentPath.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: currentPath)
        } else {
            panel.directoryURL = URL(fileURLWithPath: "/Volumes")
        }
        if panel.runModal() == .OK, let url = panel.url {
            update(url.path)
            saveSettings()
        }
    }

    func browseForDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "选择"
        panel.directoryURL = URL(fileURLWithPath: saveDirectory)
        if panel.runModal() == .OK, let url = panel.url { saveDirectory = url.path }
    }

    func openSaveDirectory() {
        let url = URL(fileURLWithPath: saveDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.open(url)
    }

    func clearLog() {
        logText = ""
    }

    func settingsChanged() {
        saveSettings()
    }

    func addScraperSource() {
        let domain = normalizedScraperDomain(newScraperDomain)
        guard !domain.isEmpty,
              !scraperSources.contains(where: { $0.domain.caseInsensitiveCompare(domain) == .orderedSame }) else { return }
        scraperSources.append(ScraperSource(id: UUID(), domain: domain, enabled: true, health: .unchecked))
        newScraperDomain = ""
        scraperSourcesChanged()
    }

    func deleteScraperSource(_ id: UUID) {
        scraperSources.removeAll { $0.id == id }
        if scraperSources.isEmpty { scraperSources = Self.defaultScraperSources }
        scraperSourcesChanged()
    }

    func moveScraperSource(_ id: UUID, offset: Int) {
        guard let index = scraperSources.firstIndex(where: { $0.id == id }) else { return }
        let destination = index + offset
        guard scraperSources.indices.contains(destination) else { return }
        scraperSources.swapAt(index, destination)
        scraperSourcesChanged()
    }

    func scraperSourcesChanged() {
        scraperDomain = enabledScraperDomains.first ?? scraperSources.first?.domain ?? "www.javbus.com"
        saveSettings()
    }

    func checkScraperSource(_ id: UUID) {
        guard let index = scraperSources.firstIndex(where: { $0.id == id }) else { return }
        scraperSources[index].health = .checking
        let domain = scraperSources[index].domain
        let testCatalog = MediaOrganizer.catalogNumber(from: catalogNumber)
            ?? MediaOrganizer.catalogNumber(from: saveName)
        Task {
            let available = await scraperSourceAvailable(domain: domain, catalog: testCatalog)
            guard let currentIndex = scraperSources.firstIndex(where: { $0.id == id }) else { return }
            scraperSources[currentIndex].health = available ? .available : .unavailable
            saveSettings()
        }
    }

    func checkAllScraperSources() {
        for source in scraperSources { checkScraperSource(source.id) }
    }

    private func scraperSourceAvailable(domain: String, catalog: String?) async -> Bool {
        let path = catalog.map { "/\($0)" } ?? ""
        guard let url = URL(string: "https://\(normalizedScraperDomain(domain))\(path)") else { return false }
        var request = URLRequest(url: url, timeoutInterval: 12)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 Chrome/124 Safari/537.36", forHTTPHeaderField: "User-Agent")
        request.setValue("zh-CN,zh;q=0.9,en;q=0.7", forHTTPHeaderField: "Accept-Language")
        request.setValue("age=verified; existmag=mag", forHTTPHeaderField: "Cookie")
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse else { return false }
        return (200..<400).contains(http.statusCode)
    }

    private func normalizedScraperDomain(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    func pasteMediaURLFromClipboard(showMissingMessage: Bool = true) {
        let pasteboard = NSPasteboard.general
        lastPasteboardChangeCount = pasteboard.changeCount
        guard let content = pasteboard.string(forType: .string), let mediaURL = firstMediaURL(in: content) else {
            if showMissingMessage { clipboardStatus = "剪贴板里没有可识别的媒体链接" }
            return
        }
        inputURL = mediaURL
        clipboardStatus = "已从剪贴板填入媒体链接"
        if autoFillBrowserTitle { fetchBrowserTitle() }
    }

    func checkClipboardForMediaURL() {
        rememberFrontmostBrowser()
        guard autoDetectClipboard else { return }
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != lastPasteboardChangeCount else { return }
        pasteMediaURLFromClipboard(showMissingMessage: false)
    }

    func fetchBrowserTitle() {
        rememberFrontmostBrowser()
        guard let bundleIdentifier = lastBrowserBundleIdentifier,
              let browser = supportedBrowser(for: bundleIdentifier) else {
            clipboardStatus = "未找到受支持的浏览器窗口"
            return
        }
        let expression = browser.usesSafariSyntax ? "name of current tab of front window" : "title of active tab of front window"
        var errorInfo: NSDictionary?
        let source = "tell application \"\(browser.applicationName)\" to get \(expression)"
        guard let result = NSAppleScript(source: source)?.executeAndReturnError(&errorInfo).stringValue else {
            clipboardStatus = "无法读取浏览器标题，请允许浏览器访问"
            return
        }
        saveName = sanitizedFileName(result)
        detectCatalogNumberFromTitle()
        clipboardStatus = "已填入链接和浏览器标题"
    }

    func detectCatalogNumberFromTitle() {
        if let detected = MediaOrganizer.catalogNumber(from: saveName) { catalogNumber = detected }
    }

    func chooseHistoricalFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.movie, .mpeg4Movie]
        panel.prompt = "选择视频"
        panel.directoryURL = URL(fileURLWithPath: saveDirectory)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        selectedHistoryFile = url.path
        saveName = url.deletingPathExtension().lastPathComponent
        detectCatalogNumberFromTitle()
        appendDisplayLog("已选择历史视频：\(url.path)")
    }

    func organizeHistoricalFile() {
        guard !isBusy, !selectedHistoryFile.isEmpty else { return }
        if catalogNumber.isEmpty { detectCatalogNumberFromTitle() }
        isOrganizing = true
        statusText = "处理历史文件"
        progressKnown = true
        progressValue = 0
        Task {
            do {
                let result = try await MediaOrganizer.organize(
                    saveDirectory: saveDirectory,
                    requestedName: saveName,
                    explicitCatalogNumber: catalogNumber,
                    explicitPerformerName: performerName,
                    startedAt: .distantPast,
                    scraperDomains: enabledScraperDomains,
                    sourceFile: URL(fileURLWithPath: selectedHistoryFile)
                ) { [weak self] value, phase in
                    self?.progressValue = value
                    self?.progressText = phase
                }
                catalogNumber = result.folderURL.lastPathComponent
                performerName = result.performerName
                appendDisplayLog("历史文件整理完成：\(result.mediaURL.path)")
                let shouldSend = nasEnabled && (result.metadataFound || nasScrapeFailureEnabled)
                if nasEnabled && !result.metadataFound && !nasScrapeFailureEnabled {
                    appendDisplayLog("未匹配到在线元数据；刮削失败发送已关闭，文件保留在本地。")
                }
                if shouldSend {
                    let destination = nasDestination(
                        metadataFound: result.metadataFound,
                        normalPath: nasDestinationPath,
                        failurePath: nasScrapeFailurePath
                    )
                    if !result.metadataFound {
                        appendDisplayLog("未匹配到在线元数据，将发送到刮削失败路径：\(destination)")
                    }
                    _ = try await sendToNAS(
                        localFolder: result.folderURL,
                        performer: result.performerName,
                        catalog: result.folderURL.lastPathComponent,
                        serverURL: nasServerURL,
                        destinationPath: destination,
                        moveAfterTransfer: nasMoveAfterTransfer,
                        taskID: nil
                    )
                }
                statusText = "已完成"
            } catch {
                appendDisplayLog("历史文件处理失败：\(error.localizedDescription)")
                statusText = "处理失败"
            }
            isOrganizing = false
            progressValue = 1
            progressText = "处理结束"
        }
    }

    private func startNextTaskIfPossible() {
        guard !isBusy, let next = tasks.first(where: { $0.state == .pending }) else {
            if !isBusy { statusText = pendingCount == 0 ? "空闲" : "等待中" }
            return
        }
        prepareTaskForLaunch(next)
    }

    private func prepareTaskForLaunch(_ task: DownloadQueueItem) {
        if task.allowDuplicateDownload != true,
           let existing = MediaDuplicateDetector.findExistingMedia(
               saveDirectory: task.saveDirectory,
               catalogNumber: task.catalogNumber,
               saveName: task.saveName
           ) {
            updateTask(task.id, persist: true) { item in
                item.state = .skipped
                item.progress = 1
                item.phase = "检测到本地文件"
                item.downloadStepResult = .skipped
                item.scrapeStepResult = .skipped
                item.nasStepResult = .skipped
                item.resultMessage = "本地已存在成片，已自动跳过下载。"
                item.outputPath = existing.path
                item.finishedAt = Date()
            }
            appendTaskLog(task.id, "执行前重复检测：本地已存在 \(existing.path)，任务已跳过。")
            statusText = "已跳过重复任务"
            startNextTaskIfPossible()
            return
        }
        if let sourcePageURL = task.sourcePageURL?.trimmingCharacters(in: .whitespacesAndNewlines),
           !sourcePageURL.isEmpty {
            isRefreshingAutoCapture = true
            selectedTaskID = task.id
            statusText = "刷新链接"
            updateTask(task.id, persist: true) { item in
                item.state = .parsing
                item.phase = "正在刷新最新播放链接"
                item.downloadStepResult = .running
            }
            appendTaskLog(task.id, "启动前刷新最新 M3U8：\(sourcePageURL)")
            Task {
                do {
                    let refreshedURL = try await JableMediaURLRefresher().refreshMediaURL(from: sourcePageURL)
                    updateTask(task.id, persist: true) { item in
                        item.inputURL = refreshedURL
                        item.phase = "已刷新最新播放链接"
                    }
                    appendTaskLog(task.id, "已刷新最新 M3U8，立即开始下载。")
                } catch {
                    appendTaskLog(task.id, "刷新最新 M3U8 失败，继续尝试使用已捕获链接：\(error.localizedDescription)")
                }
                isRefreshingAutoCapture = false
                continuePreparingTask(task.id)
            }
            return
        }
        continuePreparingTask(task.id)
    }

    private func continuePreparingTask(_ taskID: UUID) {
        guard let task = tasks.first(where: { $0.id == taskID }) else {
            startNextTaskIfPossible()
            return
        }
        guard task.nasEnabled else {
            launchDownload(taskID: task.id)
            return
        }
        isPreparingNAS = true
        selectedTaskID = task.id
        statusText = "检查 NAS"
        updateTask(task.id, persist: true) { item in
            item.state = .checkingNAS
            item.phase = "检查 NAS 挂载和写入权限"
        }
        appendTaskLog(task.id, "任务开始前检查 NAS：\(task.nasDestinationPath)")
        Task {
            let available = await ensureNASAvailable(
                serverURL: task.nasServerURL ?? nasServerURL,
                destinationPath: task.nasDestinationPath,
                taskID: task.id
            )
            isPreparingNAS = false
            if tasks.first(where: { $0.id == task.id })?.state == .cancelled {
                startNextTaskIfPossible()
                return
            }
            if available {
                appendTaskLog(task.id, "NAS 已挂载且可写，开始下载。")
                launchDownload(taskID: task.id)
            } else {
                failTask(task.id, message: "任务开始前 NAS 自动重连失败或目标路径不可写。")
                startNextTaskIfPossible()
            }
        }
    }

    private func launchDownload(taskID: UUID) {
        guard let task = tasks.first(where: { $0.id == taskID }), let resourceURL = Bundle.main.resourceURL else { return }
        updateTask(taskID, persist: true) { item in
            item.state = .parsing
            item.phase = "准备启动下载器"
            item.downloadStepResult = .running
        }
        let binaryURL = resourceURL.appendingPathComponent("N_m3u8DL-RE")
        let ffmpegURL = resourceURL.appendingPathComponent("ffmpeg")
        guard FileManager.default.isExecutableFile(atPath: binaryURL.path),
              FileManager.default.isExecutableFile(atPath: ffmpegURL.path) else {
            failTask(taskID, message: "应用内置下载核心或 FFmpeg 缺失。")
            startNextTaskIfPossible()
            return
        }

        let saveURL = URL(fileURLWithPath: task.saveDirectory)
        do { try FileManager.default.createDirectory(at: saveURL, withIntermediateDirectories: true) }
        catch {
            failTask(taskID, message: "无法创建保存目录：\(error.localizedDescription)")
            startNextTaskIfPossible()
            return
        }

        var arguments = [
            task.inputURL,
            "--auto-select",
            "--no-ansi-color",
            "--disable-update-check",
            "--thread-count", String(task.threadCount),
            "--ffmpeg-binary-path", ffmpegURL.path,
            "--save-dir", saveURL.path
        ]
        if !task.saveName.isEmpty { arguments += ["--save-name", task.saveName] }
        do { arguments += try parseCommandLine(task.extraArgs) }
        catch {
            failTask(taskID, message: "额外参数解析失败：\(error.localizedDescription)")
            startNextTaskIfPossible()
            return
        }

        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.executableURL = binaryURL
        process.arguments = arguments
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.currentDirectoryURL = saveURL
        stdoutPipe.fileHandleForReading.readabilityHandler = outputHandler(taskID: taskID)
        stderrPipe.fileHandleForReading.readabilityHandler = outputHandler(taskID: taskID)
        process.terminationHandler = { [weak self] process in
            Task { @MainActor in
                await self?.handleProcessTermination(taskID: taskID, exitCode: process.terminationStatus)
            }
        }

        activeTaskID = taskID
        selectedTaskID = taskID
        isRunning = true
        runStartDate = Date()
        statusText = "下载中"
        progressKnown = false
        progressValue = 0
        progressText = "准备启动"
        segmentText = "线程 \(task.threadCount)"
        speedText = "-"
        etaText = "-"
        self.process = process
        self.stdoutPipe = stdoutPipe
        self.stderrPipe = stderrPipe
        updateTask(taskID, persist: true) { item in
            item.state = .parsing
            item.phase = "正在启动下载器"
            item.downloadStepResult = .running
            item.startedAt = Date()
            item.finishedAt = nil
        }
        appendTaskLog(taskID, "开始执行，下载线程：\(task.threadCount)")
        do { try process.run() }
        catch {
            failTask(taskID, message: "下载器启动失败：\(error.localizedDescription)")
            cleanupProcess()
            startNextTaskIfPossible()
        }
    }

    private func outputHandler(taskID: UUID) -> @Sendable (FileHandle) -> Void {
        { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor in self?.appendTaskLog(taskID, text) }
        }
    }

    private func handleProcessTermination(taskID: UUID, exitCode: Int32) async {
        appendTaskLog(taskID, "下载进程结束，退出码：\(exitCode)")
        let wasCancelled = tasks.first(where: { $0.id == taskID })?.state == .cancelled
        if exitCode == 0 && !wasCancelled {
            updateTask(taskID, persist: true) { item in
                item.downloadStepResult = .succeeded
            }
            await runPostProcessing(taskID: taskID)
        } else if !wasCancelled {
            failTask(taskID, message: "下载失败，退出码：\(exitCode)")
        }
        cleanupProcess()
        startNextTaskIfPossible()
    }

    private func runPostProcessing(taskID: UUID) async {
        guard var task = tasks.first(where: { $0.id == taskID }) else { return }
        var localFolder: URL?
        var metadataFound = true
        if task.organizeAfterDownload {
            updateTask(taskID, persist: true) { item in
                item.state = .scraping
                item.phase = "开始刮削整理"
                item.scrapeStepResult = .running
            }
            statusText = "刮削整理"
            isOrganizing = true
            do {
                let result = try await MediaOrganizer.organize(
                    saveDirectory: task.saveDirectory,
                    requestedName: task.saveName,
                    explicitCatalogNumber: task.catalogNumber,
                    explicitPerformerName: task.performerName,
                    startedAt: task.startedAt ?? Date.distantPast,
                    scraperDomains: task.scraperDomains ?? organizationDomains(task.scraperDomain)
                ) { [weak self] value, phase in
                    self?.progressKnown = true
                    self?.progressValue = value
                    self?.progressText = phase
                    self?.updateTask(taskID) { item in
                        item.state = value < 0.4 ? .scraping : .organizing
                        item.progress = value
                        item.phase = phase
                    }
                }
                localFolder = result.folderURL
                metadataFound = result.metadataFound
                task.catalogNumber = result.folderURL.lastPathComponent
                task.performerName = result.performerName
                task.outputPath = result.mediaURL.path
                updateTask(taskID, persist: true) { item in
                    item.catalogNumber = task.catalogNumber
                    item.performerName = task.performerName
                    item.outputPath = task.outputPath
                    item.scrapeStepResult = result.metadataFound ? .succeeded : .failed
                    item.scrapeMetadataFound = result.metadataFound
                    item.reviewFolderPath = result.folderURL.path
                }
                appendTaskLog(taskID, "刮削整理完成：\(result.mediaURL.path)")
                if !result.metadataFound {
                    appendTaskLog(taskID, "未匹配到在线元数据，已生成基础元数据。")
                }
                for removed in result.removedOriginalDirectories {
                    appendTaskLog(taskID, "已删除原目录：\(removed.path)")
                }
            } catch {
                isOrganizing = false
                failTask(taskID, message: "下载成功，但刮削整理失败：\(error.localizedDescription)")
                return
            }
            isOrganizing = false
        } else if let rawMedia = MediaOrganizer.locateDownloadedMedia(
            saveDirectory: task.saveDirectory,
            requestedName: task.saveName,
            catalogNumber: task.catalogNumber,
            startedAt: task.startedAt ?? Date.distantPast
        ) {
            task.outputPath = rawMedia.path
            updateTask(taskID, persist: true) { item in item.outputPath = rawMedia.path }
        }

        await finishPostProcessing(taskID: taskID, metadataFound: metadataFound, localFolder: localFolder)
    }

    private func resumeLegacyPreviewTasksIfNeeded() {
        guard !isBusy else { return }
        guard let task = tasks.first(where: { $0.state == .awaitingReview }) else {
            startNextTaskIfPossible()
            return
        }
        guard let folder = scrapeFolder(for: task) else {
            failTask(task.id, message: "旧版待确认任务缺少刮削目录，无法自动继续。")
            resumeLegacyPreviewTasksIfNeeded()
            return
        }
        isOrganizing = true
        updateTask(task.id, persist: true) { item in
            item.state = .organizing
            item.phase = "自动继续旧版预览任务"
            item.previewBeforeCompletion = false
        }
        appendTaskLog(task.id, "新版预览无需确认，已自动继续后续步骤。")
        Task {
            await finishPostProcessing(
                taskID: task.id,
                metadataFound: task.scrapeMetadataFound ?? false,
                localFolder: folder
            )
            isOrganizing = false
            resumeLegacyPreviewTasksIfNeeded()
        }
    }

    private func finishPostProcessing(taskID: UUID, metadataFound: Bool, localFolder: URL?) async {
        guard var task = tasks.first(where: { $0.id == taskID }) else { return }
        var routedToFailurePath = false

        let failureRoutingEnabled = task.nasScrapeFailureEnabled
            ?? !(task.nasScrapeFailurePath ?? "").isEmpty
        let shouldSendToNAS = task.nasEnabled && (metadataFound || failureRoutingEnabled)
        if task.nasEnabled && !metadataFound && !failureRoutingEnabled {
            appendTaskLog(taskID, "刮削未匹配；刮削失败发送已关闭，文件保留在本地。")
            updateTask(taskID, persist: true) { item in item.nasStepResult = .skipped }
        }
        if shouldSendToNAS {
            guard let localFolder else {
                failTask(taskID, message: "NAS 发送需要先启用刮削整理。")
                return
            }
            do {
                let failurePath = task.nasScrapeFailurePath ?? ""
                let usesFailurePath = !metadataFound && failureRoutingEnabled
                    && !failurePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                routedToFailurePath = usesFailurePath
                let destination = nasDestination(
                    metadataFound: metadataFound,
                    normalPath: task.nasDestinationPath,
                    failurePath: failurePath
                )
                if !metadataFound {
                    appendTaskLog(taskID, "刮削未匹配，改为发送到刮削失败路径：\(destination)")
                }
                updateTask(taskID, persist: true) { item in
                    item.nasLastTransferPath = destination
                }
                let result = try await sendToNAS(
                    localFolder: localFolder,
                    performer: task.performerName.isEmpty ? "未知演员" : task.performerName,
                    catalog: task.catalogNumber,
                    serverURL: task.nasServerURL ?? nasServerURL,
                    destinationPath: destination,
                    moveAfterTransfer: task.nasMoveAfterTransfer,
                    taskID: taskID
                )
                appendTaskLog(taskID, "NAS 发送完成：\(result.destinationURL.path)")
                updateTask(taskID, persist: true) { item in item.nasStepResult = .succeeded }
                if task.nasMoveAfterTransfer {
                    task.outputPath = result.destinationURL.path
                }
            } catch {
                failTask(taskID, message: "下载整理成功，但 NAS 发送失败：\(error.localizedDescription)")
                return
            }
        }

        updateTask(taskID, persist: true) { item in
            item.state = .completed
            item.progress = 1
            item.phase = "全部步骤完成"
            if task.nasEnabled {
                item.resultMessage = metadataFound
                    ? "下载、刮削整理和 NAS 发送均已完成。"
                    : (routedToFailurePath
                        ? "下载完成，刮削未匹配，已发送到刮削失败路径。"
                        : "下载完成，刮削未匹配；失败发送已关闭，文件保留在本地，可重试刮削。")
            } else if task.organizeAfterDownload {
                item.resultMessage = metadataFound
                    ? "下载和刮削整理已完成。"
                    : "下载完成，刮削未匹配；基础整理已完成，文件保留在本地，可重试刮削。"
            } else {
                item.resultMessage = "下载已完成。"
            }
            item.outputPath = task.outputPath
            if !metadataFound { item.phase = "完成（刮削未匹配）" }
            item.finishedAt = Date()
        }
        statusText = "已完成"
        progressKnown = true
        progressValue = 1
        progressText = "全部完成"
    }

    private func sendToNAS(
        localFolder: URL,
        performer: String,
        catalog: String,
        serverURL: String,
        destinationPath: String,
        moveAfterTransfer: Bool,
        taskID: UUID?
    ) async throws -> NASTransferResult {
        statusText = "发送 NAS"
        if let taskID {
            updateTask(taskID, persist: true) { item in
                item.state = .nasTransferring
                item.phase = "检查 NAS 并准备发送"
                item.nasStepResult = .running
            }
        }
        guard await ensureNASAvailable(
            serverURL: serverURL,
            destinationPath: destinationPath,
            taskID: taskID
        ) else {
            throw NASTransferError.destinationUnavailable(destinationPath)
        }
        return try await NASTransfer.transfer(
            sourceFolder: localFolder,
            destinationRoot: URL(fileURLWithPath: destinationPath, isDirectory: true),
            performerName: performer,
            catalogNumber: catalog,
            moveAfterTransfer: moveAfterTransfer
        ) { [weak self] transferProgress in
            let value = transferProgress.fraction
            let phase = transferProgress.phase
            self?.progressKnown = true
            self?.progressValue = value
            self?.progressText = phase
            self?.segmentText = "NAS \(Int(value * 100))%"
            self?.speedText = self?.formatByteRate(transferProgress.bytesPerSecond) ?? "-"
            self?.etaText = self?.formatDuration(transferProgress.estimatedRemaining) ?? "-"
            if let taskID {
                self?.updateTask(taskID) { item in
                    item.state = .nasTransferring
                    item.progress = value
                    item.phase = phase
                }
            }
        }
    }

    private func ensureNASAvailable(
        serverURL: String,
        destinationPath: String,
        taskID: UUID?
    ) async -> Bool {
        if NASMountSupport.prepareAndTestPath(destinationPath) {
            nasConnectionStatus = "已挂载且可写"
            return true
        }

        nasConnectionStatus = "正在自动重连"
        statusText = "自动连接 NAS"
        if let taskID {
            appendTaskLog(taskID, "NAS 未挂载，正在自动重连...")
        } else {
            appendDisplayLog("NAS 未挂载，正在自动重连...")
        }

        guard let reconnectURL = NASMountSupport.reconnectURL(serverURL: serverURL, destinationPath: destinationPath) else {
            nasConnectionStatus = "SMB 地址无效"
            return false
        }
        NSWorkspace.shared.open(reconnectURL)

        for _ in 0..<30 {
            if let taskID, tasks.first(where: { $0.id == taskID })?.state == .cancelled {
                nasConnectionStatus = "连接已取消"
                return false
            }
            if NASMountSupport.prepareAndTestPath(destinationPath) {
                nasConnectionStatus = "自动重连成功"
                if let taskID { appendTaskLog(taskID, "NAS 自动重连成功：\(destinationPath)") }
                return true
            }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        nasConnectionStatus = "自动重连超时"
        if let taskID { appendTaskLog(taskID, "等待 NAS 挂载超时：\(destinationPath)") }
        return false
    }

    private func cleanupProcess() {
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stderrPipe?.fileHandleForReading.readabilityHandler = nil
        stdoutPipe = nil
        stderrPipe = nil
        process = nil
        activeTaskID = nil
        runStartDate = nil
        isRunning = false
        isOrganizing = false
        isPreparingNAS = false
    }

    private func failTask(_ id: UUID, message: String) {
        updateTask(id, persist: true) { task in
            switch task.state {
            case .checkingNAS:
                task.downloadStepResult = .skipped
                task.scrapeStepResult = .skipped
                task.nasStepResult = .failed
            case .pending, .parsing, .downloading, .merging:
                task.downloadStepResult = .failed
                task.scrapeStepResult = .skipped
                task.nasStepResult = .skipped
            case .scraping, .organizing:
                task.scrapeStepResult = .failed
                task.nasStepResult = .skipped
            case .awaitingReview:
                task.scrapeStepResult = .failed
            case .nasTransferring:
                task.nasStepResult = .failed
            case .completed, .skipped, .failed, .cancelled, .interrupted:
                break
            }
            task.state = .failed
            task.phase = "执行失败"
            task.resultMessage = message
            task.finishedAt = Date()
        }
        appendTaskLog(id, message)
        statusText = "任务失败"
        progressText = "失败"
    }

    private func appendTaskLog(_ id: UUID, _ text: String) {
        let block = newestFirstBlock(text)
        guard !block.isEmpty else { return }
        updateTask(id) { task in
            task.logText = block + (task.logText.isEmpty ? "" : "\n" + task.logText)
            if task.logText.count > 200_000 { task.logText = String(task.logText.prefix(200_000)) }
        }
        updateProgress(from: text, taskID: id)
        if selectedTaskID == id, let task = tasks.first(where: { $0.id == id }) {
            logText = task.logText
        }
        if Date().timeIntervalSince(lastPersistDate) > 2,
           let task = tasks.first(where: { $0.id == id }) {
            persist(task)
            lastPersistDate = Date()
        }
    }

    private func appendDisplayLog(_ text: String) {
        let block = newestFirstBlock(text)
        logText = block + (logText.isEmpty ? "" : "\n" + logText)
    }

    private func updateProgress(from text: String, taskID: UUID) {
        var state: QueueTaskState?
        if text.contains("加载URL") { progressText = "解析地址"; state = .parsing }
        if text.contains("开始下载") || text.contains("正在下载") { progressText = "下载中"; state = .downloading }
        if text.localizedCaseInsensitiveContains("合并") || text.localizedCaseInsensitiveContains("mux") {
            progressText = "合并中"
            state = .merging
        }
        let metrics = DownloadProgressParser.parse(text)
        if let value = metrics.progressPercentage {
            progressKnown = true
            progressValue = min(max(value / 100, 0), 1)
            progressText = String(format: "%.1f%%", value)
            updateETA()
        }
        if let downloaded = metrics.downloadedBytes, let total = metrics.totalBytes {
            updateTask(taskID) { task in
                task.downloadedBytes = downloaded
                task.totalBytes = total
            }
        }
        if let speed = metrics.speedText { speedText = speed }
        updateTask(taskID) { task in
            if let state { task.state = state }
            task.progress = progressValue
            task.phase = progressText
        }
    }

    private func updateETA() {
        guard progressValue > 0, progressValue < 1, let runStartDate else { return }
        let elapsed = Date().timeIntervalSince(runStartDate)
        let remaining = max(elapsed / progressValue - elapsed, 0)
        let seconds = Int(remaining.rounded())
        etaText = String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    private func formatByteRate(_ bytesPerSecond: Double) -> String {
        guard bytesPerSecond > 0 else { return "-" }
        let units = ["B/s", "KB/s", "MB/s", "GB/s"]
        var value = bytesPerSecond
        var unitIndex = 0
        while value >= 1024, unitIndex < units.count - 1 {
            value /= 1024
            unitIndex += 1
        }
        return String(format: value >= 100 ? "%.0f %@" : "%.1f %@", value, units[unitIndex])
    }

    private func formatDuration(_ interval: TimeInterval?) -> String {
        guard let interval, interval.isFinite, interval >= 0 else { return "-" }
        let seconds = Int(interval.rounded())
        if seconds >= 3600 {
            return String(format: "%02d:%02d:%02d", seconds / 3600, (seconds % 3600) / 60, seconds % 60)
        }
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    private func updateTask(_ id: UUID, persist shouldPersist: Bool = false, _ body: (inout DownloadQueueItem) -> Void) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        body(&tasks[index])
        if shouldPersist { persist(tasks[index]) }
    }

    private func persist(_ task: DownloadQueueItem) {
        try? store?.saveTask(task)
    }

    private func persistAllTasks() {
        for task in tasks { persist(task) }
    }

    private func saveSettings() {
        let settings = QueueSettings(
            downloadThreadCount: min(max(downloadThreadCount, 1), 16),
            allowDuplicateDownload: allowDuplicateDownload,
            previewBeforeCompletion: false,
            scraperSources: scraperSources,
            nasEnabled: nasEnabled,
            nasServerURL: nasServerURL,
            nasDestinationPath: nasDestinationPath,
            nasScrapeFailureEnabled: nasScrapeFailureEnabled,
            nasScrapeFailurePath: nasScrapeFailurePath,
            nasMoveAfterTransfer: nasMoveAfterTransfer
        )
        try? store?.saveSettings(settings)
    }

    private func nasDestination(
        metadataFound: Bool,
        normalPath: String,
        failurePath: String
    ) -> String {
        let trimmedFailurePath = failurePath.trimmingCharacters(in: .whitespacesAndNewlines)
        return metadataFound || trimmedFailurePath.isEmpty ? normalPath : trimmedFailurePath
    }

    private func mediaFile(for task: DownloadQueueItem) -> URL? {
        let outputURL = URL(fileURLWithPath: task.outputPath)
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: outputURL.path, isDirectory: &isDirectory) {
            if !isDirectory.boolValue { return outputURL }
            let mediaExtensions = Set(["mp4", "mkv", "ts", "mov", "m4v", "webm"])
            if let enumerator = FileManager.default.enumerator(
                at: outputURL,
                includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) {
                for case let url as URL in enumerator where mediaExtensions.contains(url.pathExtension.lowercased()) {
                    if let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                       values.isRegularFile == true,
                       (values.fileSize ?? 0) >= 1_000_000 {
                        return url
                    }
                }
            }
        }
        return MediaOrganizer.locateDownloadedMedia(
            saveDirectory: task.saveDirectory,
            requestedName: task.saveName,
            catalogNumber: task.catalogNumber,
            startedAt: .distantPast
        )
    }

    private func duplicateReason(
        inputURL: String,
        saveDirectory: String,
        catalogNumber: String,
        saveName: String
    ) -> String? {
        if let existing = MediaDuplicateDetector.findExistingMedia(
            saveDirectory: saveDirectory,
            catalogNumber: catalogNumber,
            saveName: saveName
        ) {
            return existing.path
        }

        let normalizedCatalog = MediaOrganizer.catalogNumber(from: catalogNumber)
            ?? MediaOrganizer.catalogNumber(from: saveName)
        if let history = tasks.first(where: { item in
            guard item.state == .completed else { return false }
            if item.inputURL == inputURL { return true }
            guard let normalizedCatalog else { return false }
            return MediaOrganizer.catalogNumber(from: item.catalogNumber) == normalizedCatalog
                || MediaOrganizer.catalogNumber(from: item.saveName) == normalizedCatalog
        }) {
            return history.outputPath.isEmpty ? "历史任务 \(history.displayTitle) 已完成" : history.outputPath
        }
        return nil
    }

    private func clearDraftAfterAdding() {
        inputURL = ""
        saveName = ""
        pendingSourcePageURL = ""
        catalogNumber = ""
        performerName = ""
        clipboardStatus = "任务已加入，可继续添加下一条"
    }

    private func isActiveTask(_ id: UUID) -> Bool { activeTaskID == id }

    private func organizationDomains(_ primary: String) -> [String] {
        var seen = Set<String>()
        return ([primary] + enabledScraperDomains).compactMap {
            let normalized = normalizedScraperDomain($0)
            guard !normalized.isEmpty, seen.insert(normalized.lowercased()).inserted else { return nil }
            return normalized
        }
    }

    private func rememberFrontmostBrowser() {
        guard let identifier = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
              supportedBrowser(for: identifier) != nil else { return }
        lastBrowserBundleIdentifier = identifier
    }

    private func supportedBrowser(for identifier: String) -> (applicationName: String, usesSafariSyntax: Bool)? {
        switch identifier {
        case "com.microsoft.edgemac": return ("Microsoft Edge", false)
        case "com.google.Chrome": return ("Google Chrome", false)
        case "com.apple.Safari": return ("Safari", true)
        case "com.brave.Browser": return ("Brave Browser", false)
        case "company.thebrowser.Browser": return ("Arc", false)
        default: return nil
        }
    }

    private func sanitizedFileName(_ title: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        return String(title.components(separatedBy: forbidden).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines).prefix(180))
    }

    private func firstMediaURL(in text: String) -> String? {
        firstMatch(in: text, pattern: #"(https?://[^\s\"'<>]+\.(?:m3u8|mpd|mp4)(?:\?[^\s\"'<>]*)?)"#)
    }

    private func firstMatch(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    private func newestFirstBlock(_ text: String) -> String {
        text.split(whereSeparator: \Character.isNewline).map(String.init).filter { !$0.isEmpty }.reversed().joined(separator: "\n")
    }

    private func parseCommandLine(_ input: String) throws -> [String] {
        enum ParseError: LocalizedError {
            case unterminatedQuote
            var errorDescription: String? { "额外参数中的引号没有闭合。" }
        }
        var args: [String] = []
        var current = ""
        var quote: Character?
        var escaping = false
        for character in input {
            if escaping { current.append(character); escaping = false; continue }
            if character == "\\" { escaping = true; continue }
            if let activeQuote = quote {
                if character == activeQuote { quote = nil } else { current.append(character) }
                continue
            }
            if character == "\"" || character == "'" { quote = character; continue }
            if character.isWhitespace {
                if !current.isEmpty { args.append(current); current = "" }
            } else {
                current.append(character)
            }
        }
        if quote != nil { throw ParseError.unterminatedQuote }
        if escaping { current.append("\\") }
        if !current.isEmpty { args.append(current) }
        return args
    }
}
