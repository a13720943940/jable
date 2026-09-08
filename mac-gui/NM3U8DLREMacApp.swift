import SwiftUI
import AppKit
import Foundation
import UniformTypeIdentifiers

@MainActor
final class DownloadViewModel: ObservableObject {
    @Published var inputURL: String = ""
    @Published var saveDirectory: String = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Downloads/N_m3u8DL-RE").path
    @Published var saveName: String = ""
    @Published var extraArgs: String = ""
    @Published var logText: String = "已就绪。\n"
    @Published var statusText: String = "空闲"
    @Published var progressValue: Double = 0
    @Published var progressKnown: Bool = false
    @Published var progressText: String = "等待开始"
    @Published var segmentText: String = "未开始"
    @Published var speedText: String = "-"
    @Published var etaText: String = "-"
    @Published var isRunning: Bool = false
    @Published var autoDetectClipboard: Bool = true
    @Published var autoFillBrowserTitle: Bool = true
    @Published var clipboardStatus: String = "复制 m3u8、mpd 或 mp4 链接后会自动填入"
    @Published var organizeAfterDownload: Bool = true
    @Published var catalogNumber: String = ""
    @Published var performerName: String = ""
    @Published var scraperDomain: String = "www.javbus.com"
    @Published var selectedHistoryFile: String = ""
    @Published var isOrganizing: Bool = false

    var isBusy: Bool { isRunning || isOrganizing }

    private var process: Process?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private var runStartDate: Date?
    private var lastPasteboardChangeCount: Int = NSPasteboard.general.changeCount
    private var lastBrowserBundleIdentifier: String?

    func pasteMediaURLFromClipboard(showMissingMessage: Bool = true) {
        let pasteboard = NSPasteboard.general
        lastPasteboardChangeCount = pasteboard.changeCount

        guard let content = pasteboard.string(forType: .string),
              let mediaURL = firstMediaURL(in: content) else {
            if showMissingMessage {
                clipboardStatus = "剪贴板里没有可识别的媒体链接"
            }
            return
        }

        inputURL = mediaURL
        clipboardStatus = "已从剪贴板填入媒体链接"
        if autoFillBrowserTitle {
            fetchBrowserTitle()
        }
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

        let expression = browser.usesSafariSyntax
            ? "name of current tab of front window"
            : "title of active tab of front window"
        let source = "tell application \"\(browser.applicationName)\" to get \(expression)"
        var errorInfo: NSDictionary?
        guard let result = NSAppleScript(source: source)?.executeAndReturnError(&errorInfo).stringValue,
              !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            clipboardStatus = "无法读取浏览器标题，请在系统提示中允许访问"
            return
        }

        saveName = sanitizedFileName(result)
        detectCatalogNumberFromTitle()
        clipboardStatus = "已填入链接和浏览器标题"
    }

    func detectCatalogNumberFromTitle() {
        if let detected = MediaOrganizer.catalogNumber(from: saveName) {
            catalogNumber = detected
        }
    }

    private func rememberFrontmostBrowser() {
        guard let bundleIdentifier = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
              supportedBrowser(for: bundleIdentifier) != nil else { return }
        lastBrowserBundleIdentifier = bundleIdentifier
    }

    private func supportedBrowser(for bundleIdentifier: String) -> (applicationName: String, usesSafariSyntax: Bool)? {
        switch bundleIdentifier {
        case "com.microsoft.edgemac":
            return ("Microsoft Edge", false)
        case "com.google.Chrome":
            return ("Google Chrome", false)
        case "com.apple.Safari":
            return ("Safari", true)
        case "com.brave.Browser":
            return ("Brave Browser", false)
        case "company.thebrowser.Browser":
            return ("Arc", false)
        default:
            return nil
        }
    }

    private func sanitizedFileName(_ title: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        let cleaned = title.components(separatedBy: forbidden).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(cleaned.prefix(180))
    }

    func browseForDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "选择"
        panel.directoryURL = URL(fileURLWithPath: saveDirectory)
        if panel.runModal() == .OK, let url = panel.url {
            saveDirectory = url.path
        }
    }

    func chooseHistoricalFile() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.movie, .mpeg4Movie]
        panel.prompt = "选择视频"
        panel.directoryURL = URL(fileURLWithPath: saveDirectory)
        guard panel.runModal() == .OK, let url = panel.url else { return }

        selectedHistoryFile = url.path
        saveName = url.deletingPathExtension().lastPathComponent
        detectCatalogNumberFromTitle()

        let currentRoot = URL(fileURLWithPath: saveDirectory, isDirectory: true).standardizedFileURL.path
        if !url.standardizedFileURL.path.hasPrefix(currentRoot + "/") {
            let parent = url.deletingLastPathComponent()
            saveDirectory = MediaOrganizer.catalogNumber(from: parent.lastPathComponent) == nil
                ? parent.path
                : parent.deletingLastPathComponent().path
        }
        appendLog("已选择历史视频：\(url.path)\n")
    }

    func organizeHistoricalFile() {
        guard !isBusy else { return }
        let trimmedPath = selectedHistoryFile.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else {
            appendLog("请先选择需要刮削整理的历史视频。\n")
            return
        }
        if catalogNumber.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            detectCatalogNumberFromTitle()
        }

        isOrganizing = true
        statusText = "正在刮削"
        progressKnown = true
        progressValue = 0
        progressText = "准备历史文件"
        segmentText = "手动整理"
        speedText = "-"
        etaText = "-"
        appendLog("开始处理历史视频...\n")

        Task {
            await performOrganization(
                sourceFile: URL(fileURLWithPath: trimmedPath),
                startedAt: .distantPast,
                logPrefix: "历史文件"
            )
            isOrganizing = false
            finishRun(status: "已完成")
        }
    }

    func openSaveDirectory() {
        let url = URL(fileURLWithPath: saveDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.open(url)
    }

    func clearLog() {
        logText = ""
        statusText = "空闲"
        progressValue = 0
        progressKnown = false
        progressText = "等待开始"
        segmentText = "未开始"
        speedText = "-"
        etaText = "-"
    }

    func stopDownload() {
        process?.terminate()
        appendLog("\n已由用户停止。\n")
        finishRun(status: "已停止")
    }

    func startDownload() {
        guard !isRunning else { return }
        let trimmedInput = inputURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedInput.isEmpty else {
            statusText = "需要输入"
            appendLog("请输入 m3u8/mpd 链接，或本地清单文件路径。\n")
            return
        }

        if catalogNumber.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            detectCatalogNumberFromTitle()
        }

        guard let resourceURL = Bundle.main.resourceURL else {
            statusText = "程序资源异常"
            appendLog("无法定位应用内资源文件。\n")
            return
        }

        let binaryURL = resourceURL.appendingPathComponent("N_m3u8DL-RE")
        let ffmpegURL = resourceURL.appendingPathComponent("ffmpeg")

        guard FileManager.default.isExecutableFile(atPath: binaryURL.path) else {
            statusText = "主程序缺失"
            appendLog("应用内置的 N_m3u8DL-RE 不存在或不可执行。\n")
            return
        }

        guard FileManager.default.isExecutableFile(atPath: ffmpegURL.path) else {
            statusText = "FFmpeg 缺失"
            appendLog("应用内置的 ffmpeg 不存在或不可执行。\n")
            return
        }

        let saveURL = URL(fileURLWithPath: saveDirectory)
        do {
            try FileManager.default.createDirectory(at: saveURL, withIntermediateDirectories: true)
        } catch {
            statusText = "目录异常"
            appendLog("无法创建保存目录：\(error.localizedDescription)\n")
            return
        }

        var arguments: [String] = [
            trimmedInput,
            "--auto-select",
            "--no-ansi-color",
            "--disable-update-check",
            "--ffmpeg-binary-path", ffmpegURL.path,
            "--save-dir", saveURL.path
        ]

        let trimmedSaveName = saveName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedSaveName.isEmpty {
            arguments.append(contentsOf: ["--save-name", trimmedSaveName])
        }

        do {
            arguments.append(contentsOf: try parseCommandLine(extraArgs))
        } catch {
            statusText = "参数异常"
            appendLog("额外参数解析失败：\(error.localizedDescription)\n")
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

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor in
                self?.appendLog(text)
            }
        }

        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor in
                self?.appendLog(text)
            }
        }

        process.terminationHandler = { [weak self] process in
            Task { @MainActor in
                self?.appendLog("\n进程已结束，退出码：\(process.terminationStatus)\n")
                if process.terminationStatus == 0 {
                    await self?.handleSuccessfulRun()
                } else {
                    self?.finishRun(status: "退出 \(process.terminationStatus)")
                }
            }
        }

        do {
            logText = ""
            statusText = "运行中"
            progressValue = 0
            progressKnown = false
            progressText = "准备启动"
            segmentText = "准备中"
            speedText = "-"
            etaText = "-"
            isRunning = true
            runStartDate = Date()
            self.process = process
            self.stdoutPipe = stdoutPipe
            self.stderrPipe = stderrPipe
            appendLog("正在启动下载器...\n\n")
            try process.run()
        } catch {
            appendLog("启动失败：\(error.localizedDescription)\n")
            finishRun(status: "启动失败")
        }
    }

    private func handleSuccessfulRun() async {
        guard organizeAfterDownload else {
            finishRun(status: "已完成")
            return
        }
        guard let runStartDate else {
            appendLog("无法确定任务开始时间，已跳过自动整理。\n")
            finishRun(status: "已完成")
            return
        }

        statusText = "正在整理"
        progressKnown = true
        progressValue = 0
        progressText = "整理与刮削"
        segmentText = "下载完成"
        appendLog("开始整理文件并刮削元数据...\n")
        await performOrganization(sourceFile: nil, startedAt: runStartDate, logPrefix: "下载文件")
        finishRun(status: "已完成")
    }

    private func performOrganization(sourceFile: URL?, startedAt: Date, logPrefix: String) async {
        do {
            let result = try await MediaOrganizer.organize(
                saveDirectory: saveDirectory,
                requestedName: saveName,
                explicitCatalogNumber: catalogNumber,
                explicitPerformerName: performerName,
                startedAt: startedAt,
                scraperDomains: organizationDomains(),
                sourceFile: sourceFile
            ) { [weak self] value, phase in
                self?.progressKnown = true
                self?.progressValue = value
                self?.progressText = phase
                self?.segmentText = "刮削 \(Int(value * 100))%"
            }
            catalogNumber = result.folderURL.lastPathComponent
            performerName = result.performerName
            appendLog("\(logPrefix)整理完成：\(result.mediaURL.path)\n")
            if result.metadataFound {
                appendLog("元数据、NFO、封面和海报已生成。\n")
            } else {
                appendLog("元数据站点暂时不可用，已生成基础 metadata.json 和 NFO。\n")
            }
            for removed in result.removedOriginalDirectories {
                appendLog("已删除原目录：\(removed.path)\n")
            }
        } catch {
            appendLog("\(logPrefix)整理未完成：\(error.localizedDescription)\n")
        }
    }

    private func organizationDomains() -> [String] {
        let primaryDomain = scraperDomain.trimmingCharacters(in: .whitespacesAndNewlines)
        return [primaryDomain, "www.busdmm.ink", "www.dmmsee.bond"].filter { !$0.isEmpty }
    }

    private func finishRun(status: String) {
        isRunning = false
        statusText = status
        if status == "已完成" {
            progressKnown = true
            progressValue = 1
            progressText = "100%"
        } else if status == "已停止" {
            progressText = "已停止"
        } else if status.hasPrefix("退出") || status == "启动失败" {
            progressText = "执行失败"
        }
        if status == "已完成" {
            etaText = "00:00"
        }
        process = nil
        runStartDate = nil
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stderrPipe?.fileHandleForReading.readabilityHandler = nil
        stdoutPipe = nil
        stderrPipe = nil
    }

    private func appendLog(_ text: String) {
        updateProgress(from: text)
        let lines = text
            .split(whereSeparator: \Character.isNewline)
            .map(String.init)
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return }
        let newestFirst = lines.reversed().joined(separator: "\n")
        logText = newestFirst + (logText.isEmpty ? "" : "\n" + logText)
    }

    private func updateProgress(from text: String) {
        if text.contains("正在启动下载器") {
            progressText = "正在启动"
        }

        if text.contains("加载URL") {
            progressText = "正在解析地址"
            segmentText = "等待分片信息"
        }

        if text.contains("选定") || text.contains("选择音频") || text.contains("选择视频") {
            progressText = "正在选择轨道"
        }

        if text.contains("开始下载") || text.contains("正在下载") {
            progressText = "正在下载"
        }

        if text.contains("合并") || text.contains("mux") || text.contains("ffmpeg") {
            progressText = "正在合并"
            segmentText = "下载完成"
        }

        if let percent = firstMatch(in: text, pattern: #"(\d+(?:\.\d+)?)%"#),
           let value = Double(percent) {
            progressKnown = true
            progressValue = min(max(value / 100.0, 0), 1)
            progressText = String(format: "%.1f%%", value)
            updateETA()
            return
        }

        if let currentString = firstMatch(in: text, pattern: #"(?:已下载|Downloaded|downloaded|segments?)\D*(\d+)\D+(\d+)"#, group: 1),
           let totalString = firstMatch(in: text, pattern: #"(?:已下载|Downloaded|downloaded|segments?)\D*(\d+)\D+(\d+)"#, group: 2),
           let current = Double(currentString),
           let total = Double(totalString),
           total > 0 {
            progressKnown = true
            progressValue = min(max(current / total, 0), 1)
            progressText = "\(Int(current))/\(Int(total))"
            segmentText = "\(Int(current)) / \(Int(total)) 分片"
            updateETA()
            return
        }

        if let currentString = firstMatch(in: text, pattern: #"\((\d+)\/(\d+)\)"#, group: 1),
           let totalString = firstMatch(in: text, pattern: #"\((\d+)\/(\d+)\)"#, group: 2),
           let current = Double(currentString),
           let total = Double(totalString),
           total > 0,
           (text.contains("已下载") || text.contains("下载") || text.contains("segments") || text.contains("segment")) {
            progressKnown = true
            progressValue = min(max(current / total, 0), 1)
            progressText = "\(Int(current))/\(Int(total))"
            segmentText = "\(Int(current)) / \(Int(total)) 分片"
            updateETA()
        }

        if let speed = firstMatch(in: text, pattern: #"speed=\s*([0-9.]+x)"#) {
            speedText = speed
        } else if let speed = firstMatch(in: text, pattern: #"([0-9.]+\s*(?:[KMG]i?B/s|[KMG]B/s|kb/s|KB/s|MB/s|GB/s))"#) {
            speedText = speed.replacingOccurrences(of: " ", with: "")
        }
    }

    private func updateETA() {
        guard progressKnown, progressValue > 0, progressValue < 1, let runStartDate else {
            if progressValue >= 1 {
                etaText = "00:00"
            }
            return
        }

        let elapsed = Date().timeIntervalSince(runStartDate)
        guard elapsed > 1 else { return }
        let totalEstimate = elapsed / progressValue
        let remaining = max(totalEstimate - elapsed, 0)
        etaText = formatDuration(remaining)
    }

    private func formatDuration(_ interval: TimeInterval) -> String {
        let totalSeconds = Int(interval.rounded())
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 {
            return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }

    private func firstMatch(in text: String, pattern: String, group: Int = 1) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range), match.numberOfRanges > group,
              let matchedRange = Range(match.range(at: group), in: text) else { return nil }
        return String(text[matchedRange])
    }

    private func firstMediaURL(in text: String) -> String? {
        let pattern = #"https?://[^\s\"'<>]+\.(?:m3u8|mpd|mp4)(?:\?[^\s\"'<>]*)?"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let matchedRange = Range(match.range, in: text) else {
            return nil
        }
        return String(text[matchedRange])
    }

    private func parseCommandLine(_ input: String) throws -> [String] {
        enum ParseError: LocalizedError {
            case unterminatedQuote
            var errorDescription: String? {
                switch self {
                case .unterminatedQuote:
                    return "额外参数中的引号没有正确闭合。"
                }
            }
        }

        var args: [String] = []
        var current = ""
        var quote: Character?
        var isEscaping = false

        for char in input {
            if isEscaping {
                current.append(char)
                isEscaping = false
                continue
            }

            if char == "\\" {
                isEscaping = true
                continue
            }

            if let activeQuote = quote {
                if char == activeQuote {
                    quote = nil
                } else {
                    current.append(char)
                }
                continue
            }

            if char == "\"" || char == "'" {
                quote = char
                continue
            }

            if char.isWhitespace {
                if !current.isEmpty {
                    args.append(current)
                    current.removeAll(keepingCapacity: true)
                }
                continue
            }

            current.append(char)
        }

        if isEscaping {
            current.append("\\")
        }

        if quote != nil {
            throw ParseError.unterminatedQuote
        }

        if !current.isEmpty {
            args.append(current)
        }

        return args
    }
}

struct ContentView: View {
    @StateObject private var viewModel = QueueDownloadViewModel()
    private let clipboardTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 14) {
            HStack(alignment: .center) {
                Button {
                    viewModel.showingJableCatalog = true
                } label: {
                    Label("自动影片库", systemImage: "film.stack")
                }
                Spacer()
                Text("等待 \(viewModel.pendingCount)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Label(viewModel.statusText, systemImage: viewModel.isBusy ? "bolt.fill" : "checkmark.circle")
                    .padding(.horizontal, 11)
                    .padding(.vertical, 6)
                    .background(viewModel.isBusy ? Color.orange.opacity(0.14) : Color.green.opacity(0.14))
                    .clipShape(Capsule())
            }
            .padding(.bottom, 8)

            HStack(alignment: .top, spacing: 10) {
                GroupBox("下载任务") {
                    VStack(spacing: 7) {
                        HStack(spacing: 6) {
                            CompactField(title: "下载地址", text: $viewModel.inputURL, prompt: "m3u8 / mpd / mp4 / 本地清单")
                            Color.clear.frame(width: 74, height: 1)
                        }
                        HStack(spacing: 6) {
                            CompactField(title: "保存目录", text: $viewModel.saveDirectory, prompt: "/Users/you/Downloads")
                            Button("浏览") { viewModel.browseForDirectory() }
                                .frame(width: 74)
                        }
                        HStack(spacing: 6) {
                            CompactField(title: "文件标题", text: $viewModel.saveName, prompt: "自动或手动填写")
                            Button("取标题") { viewModel.fetchBrowserTitle() }
                                .frame(width: 74)
                        }
                        HStack(spacing: 6) {
                            CompactField(title: "额外参数", text: $viewModel.extraArgs, prompt: "可选")
                            Color.clear.frame(width: 74, height: 1)
                        }

                        HStack {
                            Text("下载线程")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(width: 54, alignment: .trailing)
                            Stepper(value: $viewModel.downloadThreadCount, in: 1...16) {
                                Text("\(viewModel.downloadThreadCount)")
                                    .font(.body.monospacedDigit())
                                    .frame(width: 24)
                            }
                            Spacer()
                            Text("单个影片分片并发，任务仍按队列执行")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        HStack {
                            Text("重复下载")
                                .foregroundStyle(.secondary)
                                .frame(width: 54, alignment: .trailing)
                            Toggle("允许", isOn: $viewModel.allowDuplicateDownload)
                                .toggleStyle(.checkbox)
                            Spacer()
                            Text("关闭时检查本地文件和已完成历史")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .font(.caption)

                        HStack(spacing: 10) {
                            Text("自动填充")
                                .foregroundStyle(.secondary)
                                .frame(width: 54, alignment: .trailing)
                            Toggle("监测剪贴板", isOn: $viewModel.autoDetectClipboard)
                            Toggle("同时取标题", isOn: $viewModel.autoFillBrowserTitle)
                            Spacer()
                            Button("粘贴链接") { viewModel.pasteMediaURLFromClipboard() }
                                .frame(width: 92)
                        }
                        .toggleStyle(.checkbox)
                        .font(.caption)

                        HStack(spacing: 7) {
                            Color.clear.frame(width: 54, height: 1)
                            Button(action: viewModel.startDownload) {
                                Label("加入队列", systemImage: "plus.circle.fill")
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(viewModel.inputURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            Button(action: viewModel.stopDownload) {
                                Label("停止", systemImage: "stop.fill")
                            }
                            .disabled(!viewModel.isRunning)
                            Button("打开目录") { viewModel.openSaveDirectory() }
                            Spacer()
                        }
                    }
                    .padding(8)
                }
                .frame(maxWidth: .infinity)

                GroupBox("刮削与整理") {
                    VStack(spacing: 7) {
                        HStack {
                            Toggle("下载完成后自动执行", isOn: $viewModel.organizeAfterDownload)
                                .toggleStyle(.switch)
                            Spacer()
                            Text("完成后可在任务列表查看刮削结果")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        HStack(spacing: 6) {
                            CompactField(title: "番号", text: $viewModel.catalogNumber, prompt: "例如 SAME-246")
                            Button("识别") { viewModel.detectCatalogNumberFromTitle() }
                        }
                        CompactField(title: "演员", text: $viewModel.performerName, prompt: "留空时从元数据自动获取")
                        HStack(spacing: 6) {
                            CompactField(title: "元数据源", text: $viewModel.scraperDomain, prompt: "www.javbus.com")
                                .disabled(true)
                            Button("管理") { viewModel.showingSourceManager = true }
                                .frame(width: 68)
                        }
                        HStack(spacing: 6) {
                            CompactField(title: "历史视频", text: $viewModel.selectedHistoryFile, prompt: "选择已下载的视频文件")
                            Button("选择") { viewModel.chooseHistoricalFile() }
                        }
                        HStack(spacing: 7) {
                            Button(action: viewModel.organizeHistoricalFile) {
                                Label("刮削所选历史文件", systemImage: "wand.and.stars")
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(viewModel.isBusy || viewModel.selectedHistoryFile.isEmpty)
                            Spacer()
                            Text("整理为 演员/番号/番号.mp4")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(8)
                }
                .frame(maxWidth: .infinity)

                GroupBox("NAS 发送") {
                    VStack(spacing: 7) {
                        HStack {
                            Toggle("刮削后发送到 NAS", isOn: $viewModel.nasEnabled)
                                .toggleStyle(.switch)
                            Spacer()
                            Text(viewModel.nasEnabled ? "已启用" : "已关闭")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        HStack(spacing: 6) {
                            CompactField(title: "SMB 地址", text: $viewModel.nasServerURL, prompt: "smb://192.168.1.10/Media")
                            Button("连接") { viewModel.connectNAS() }
                                .frame(width: 68)
                        }
                        HStack(spacing: 6) {
                            CompactField(title: "目标路径", text: $viewModel.nasDestinationPath, prompt: "/Volumes/Media/影片")
                            Button("选择") { viewModel.browseNASDestination() }
                                .frame(width: 68)
                        }
                        HStack(spacing: 6) {
                            Toggle("刮削失败时发送", isOn: $viewModel.nasScrapeFailureEnabled)
                                .toggleStyle(.switch)
                            Spacer()
                            Text(viewModel.nasScrapeFailureEnabled ? "发送到单独目录" : "保留本地，不发送")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        HStack(spacing: 6) {
                            CompactField(title: "失败路径", text: $viewModel.nasScrapeFailurePath, prompt: "/Volumes/Media/待整理")
                                .disabled(!viewModel.nasScrapeFailureEnabled || !viewModel.nasEnabled)
                            Button("选择") { viewModel.browseNASScrapeFailureDestination() }
                                .disabled(!viewModel.nasScrapeFailureEnabled || !viewModel.nasEnabled)
                                .frame(width: 68)
                        }
                        HStack {
                            Toggle("发送成功后删除本地整理目录", isOn: $viewModel.nasMoveAfterTransfer)
                                .toggleStyle(.switch)
                            Spacer()
                            Text(viewModel.nasMoveAfterTransfer ? "发送后删除本地" : "保留本地文件")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        VStack(alignment: .leading, spacing: 5) {
                            Label("状态：\(viewModel.nasConnectionStatus)", systemImage: "network")
                            Label("密码由 macOS 登录窗口和钥匙串管理", systemImage: "key.fill")
                            Label("NAS 结构保持为 演员/番号/番号.mp4", systemImage: "externaldrive.connected.to.line.below")
                            Label("任务前检查，断线时自动重连 30 秒", systemImage: "arrow.clockwise")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Spacer()
                    }
                    .padding(8)
                }
                .frame(maxWidth: .infinity)
            }
            .frame(height: 270)

            GroupBox {
                VStack(spacing: 7) {
                    HStack {
                        Text(viewModel.isOrganizing ? "刮削进度" : "任务进度")
                            .font(.headline)
                        Spacer()
                        Text(viewModel.progressText)
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    if viewModel.progressKnown {
                        ProgressView(value: viewModel.progressValue)
                            .progressViewStyle(.linear)
                    } else {
                        ProgressView()
                            .progressViewStyle(.linear)
                    }
                    HStack(spacing: 8) {
                        ProgressStatCard(title: "阶段 / 分片", value: viewModel.segmentText)
                        ProgressStatCard(title: "当前速度", value: viewModel.speedText)
                        ProgressStatCard(title: "预计剩余", value: viewModel.etaText)
                    }
                }
                .padding(8)
            }

            HStack(spacing: 10) {
                GroupBox {
                    VStack(spacing: 6) {
                        HStack {
                            Picker("筛选", selection: $viewModel.taskFilter) {
                                ForEach(TaskListFilter.allCases) { filter in
                                    Text(filter.rawValue).tag(filter)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            Spacer()
                            Text("完成 \(viewModel.completedTaskCount) · 失败 \(viewModel.failedTaskCount) · 刮削失败 \(viewModel.scrapeFailedTaskCount) · \(ByteCountFormatter.string(fromByteCount: viewModel.totalCompletedBytes, countStyle: .binary))")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        ScrollView {
                            LazyVStack(spacing: 6) {
                            if viewModel.filteredTasks.isEmpty {
                                VStack(spacing: 8) {
                                    Image(systemName: "tray")
                                        .font(.title2)
                                        .foregroundStyle(.secondary)
                                    Text(viewModel.tasks.isEmpty ? "暂无任务" : "当前筛选没有任务")
                                        .font(.headline)
                                    Text(viewModel.tasks.isEmpty ? "填写链接后点击“加入队列”" : "请选择其他筛选条件")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity, minHeight: 150)
                            } else {
                                ForEach(viewModel.filteredTasks) { item in
                                    QueueTaskRow(
                                        item: item,
                                        coverPath: viewModel.scrapeCoverPath(for: item),
                                        isSelected: viewModel.selectedTaskID == item.id,
                                        onSelect: { viewModel.selectTask(item.id) },
                                        onRetry: { viewModel.retryTask(item.id) },
                                        onRetryScrape: { viewModel.retryScraping(item.id, useCurrentSource: false) },
                                        onRetryScrapeWithCurrentSource: { viewModel.retryScraping(item.id, useCurrentSource: true) },
                                        onPreview: { viewModel.openScrapePreview(item.id) },
                                        onCancel: { viewModel.cancelPendingTask(item.id) },
                                        onDelete: { viewModel.deleteTask(item.id) },
                                        onMoveFirst: { viewModel.moveTaskToFront(item.id) },
                                        onOpen: { viewModel.openTaskOutput(item.id) }
                                    )
                                }
                            }
                        }
                        .padding(4)
                    }
                    }
                } label: {
                    HStack {
                        Text("任务队列")
                        Spacer()
                        Text("共 \(viewModel.tasks.count) 项")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                GroupBox {
                    TextEditor(text: $viewModel.logText)
                        .font(.system(size: 12, design: .monospaced))
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .background(Color.black.opacity(0.92))
                        .foregroundStyle(Color.green.opacity(0.95))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } label: {
                    HStack {
                        Text("选中任务日志（最新在上）")
                        Spacer()
                        Button("清空显示") { viewModel.clearLog() }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxHeight: .infinity)
        }
        .padding(12)
        .frame(minWidth: 1120, minHeight: 760)
        .background(
            LinearGradient(
                colors: [Color(red: 0.97, green: 0.98, blue: 0.95), Color(red: 0.92, green: 0.95, blue: 0.98)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .overlay(alignment: .top) {
            if viewModel.showingTaskAddedNotice {
                TaskAddedToast(text: viewModel.taskAddedNotice)
                    .padding(.top, 18)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .sheet(isPresented: $viewModel.showingScrapePreview) {
            ScrapePreviewSheet(viewModel: viewModel)
        }
        .sheet(isPresented: $viewModel.showingSourceManager) {
            ScraperSourceManagerSheet(viewModel: viewModel)
        }
        .sheet(isPresented: $viewModel.showingJableCatalog) {
            JableCatalogBrowserSheet(viewModel: viewModel)
        }
        .onReceive(clipboardTimer) { _ in
            viewModel.checkClipboardForMediaURL()
        }
        .onReceive(viewModel.$downloadThreadCount.dropFirst()) { _ in viewModel.settingsChanged() }
        .onReceive(viewModel.$allowDuplicateDownload.dropFirst()) { _ in viewModel.settingsChanged() }
        .onReceive(viewModel.$nasEnabled.dropFirst()) { _ in viewModel.settingsChanged() }
        .onReceive(viewModel.$nasMoveAfterTransfer.dropFirst()) { _ in viewModel.settingsChanged() }
        .onReceive(viewModel.$nasScrapeFailureEnabled.dropFirst()) { _ in viewModel.settingsChanged() }
        .onReceive(viewModel.$nasScrapeFailurePath.dropFirst()) { _ in viewModel.settingsChanged() }
    }
}

struct TaskAddedToast: View {
    let text: String

    private var lines: [String] {
        text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(Color.white)
            VStack(alignment: .leading, spacing: 3) {
                Text(lines.first ?? "添加成功")
                    .font(.headline.bold())
                    .foregroundStyle(Color.white)
                if lines.count > 1 {
                    Text(lines.dropFirst().joined(separator: "\n"))
                        .font(.subheadline)
                        .foregroundStyle(Color.white.opacity(0.94))
                        .lineLimit(2)
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.black.opacity(0.82))
        )
        .shadow(color: Color.black.opacity(0.18), radius: 12, y: 8)
    }
}

struct CompactField: View {
    let title: String
    @Binding var text: String
    let prompt: String

    var body: some View {
        HStack(spacing: 7) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 54, alignment: .trailing)
            TextField(prompt, text: $text)
                .textFieldStyle(.roundedBorder)
        }
        .frame(maxWidth: .infinity)
    }
}

struct LabeledField: View {
    let title: String
    @Binding var text: String
    let prompt: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.headline)
            TextField(prompt, text: $text)
                .textFieldStyle(.roundedBorder)
        }
    }
}

struct ProgressStatCard: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.white.opacity(0.7))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

struct ScrapePreviewSheet: View {
    @ObservedObject var viewModel: QueueDownloadViewModel
    @Environment(\.dismiss) private var dismiss

    private var task: DownloadQueueItem? {
        viewModel.tasks.first { $0.id == viewModel.previewTaskID }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("刮削结果")
                        .font(.title2.bold())
                    Text(task?.displayTitle ?? "未知任务")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Label(
                    task?.scrapeMetadataFound == true ? "已匹配元数据" : "未匹配元数据",
                    systemImage: task?.scrapeMetadataFound == true ? "checkmark.seal.fill" : "exclamationmark.triangle.fill"
                )
                .foregroundStyle(task?.scrapeMetadataFound == true ? Color.green : Color.orange)
            }

            HStack(alignment: .top, spacing: 16) {
                Group {
                    if !viewModel.previewCoverPath.isEmpty,
                       let image = NSImage(contentsOfFile: viewModel.previewCoverPath) {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFit()
                    } else {
                        ZStack {
                            Color.secondary.opacity(0.1)
                            Image(systemName: "photo")
                                .font(.largeTitle)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(width: 210, height: 295)
                .clipShape(RoundedRectangle(cornerRadius: 10))

                VStack(spacing: 10) {
                    LabeledField(title: "标题", text: $viewModel.previewTitle, prompt: "影片标题")
                    HStack(spacing: 10) {
                        LabeledField(title: "演员", text: $viewModel.previewPerformer, prompt: "未知演员")
                        LabeledField(title: "发行日期", text: $viewModel.previewReleaseDate, prompt: "YYYY-MM-DD")
                    }
                    LabeledField(title: "标签（逗号分隔）", text: $viewModel.previewKeywords, prompt: "标签")
                    VStack(alignment: .leading, spacing: 6) {
                        Text("简介").font(.headline)
                        TextEditor(text: $viewModel.previewDescription)
                            .font(.body)
                            .padding(5)
                            .background(Color.white.opacity(0.7))
                            .clipShape(RoundedRectangle(cornerRadius: 7))
                    }
                }
                .disabled(true)
            }

            HStack {
                Button("关闭") { dismiss() }
                Spacer()
            }
        }
        .padding(20)
        .frame(width: 760, height: 500)
    }
}

struct ScraperSourceManagerSheet: View {
    @ObservedObject var viewModel: QueueDownloadViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("刮削源管理").font(.title2.bold())
                    Text("按从上到下的顺序尝试已启用来源")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("检测全部") { viewModel.checkAllScraperSources() }
                Button("完成") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }

            List {
                ForEach(Array(viewModel.scraperSources.enumerated()), id: \.element.id) { index, source in
                    HStack(spacing: 8) {
                        Toggle("", isOn: Binding(
                            get: { viewModel.scraperSources[index].enabled },
                            set: { value in
                                viewModel.scraperSources[index].enabled = value
                                viewModel.scraperSourcesChanged()
                            }
                        ))
                        .labelsHidden()
                        Text("\(index + 1)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 18)
                        TextField("域名", text: Binding(
                            get: { viewModel.scraperSources[index].domain },
                            set: { value in
                                viewModel.scraperSources[index].domain = value
                                viewModel.scraperSources[index].health = .unchecked
                                viewModel.scraperSourcesChanged()
                            }
                        ))
                        .textFieldStyle(.roundedBorder)
                        Label(source.health.displayName, systemImage: healthIcon(source.health))
                            .font(.caption)
                            .foregroundStyle(healthColor(source.health))
                            .frame(width: 78, alignment: .leading)
                        Button { viewModel.checkScraperSource(source.id) } label: {
                            Image(systemName: "wave.3.right")
                        }
                        Button { viewModel.moveScraperSource(source.id, offset: -1) } label: {
                            Image(systemName: "arrow.up")
                        }
                        .disabled(index == 0)
                        Button { viewModel.moveScraperSource(source.id, offset: 1) } label: {
                            Image(systemName: "arrow.down")
                        }
                        .disabled(index == viewModel.scraperSources.count - 1)
                        Button(role: .destructive) { viewModel.deleteScraperSource(source.id) } label: {
                            Image(systemName: "trash")
                        }
                    }
                }
            }

            HStack {
                TextField("添加域名，例如 www.example.com", text: $viewModel.newScraperDomain)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { viewModel.addScraperSource() }
                Button("添加") { viewModel.addScraperSource() }
                    .disabled(viewModel.newScraperDomain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 720, height: 440)
    }

    private func healthColor(_ health: ScraperSourceHealth) -> Color {
        switch health {
        case .available: return .green
        case .unavailable: return .red
        case .checking: return .blue
        case .unchecked: return .secondary
        }
    }

    private func healthIcon(_ health: ScraperSourceHealth) -> String {
        switch health {
        case .available: return "checkmark.circle.fill"
        case .unavailable: return "xmark.circle.fill"
        case .checking: return "arrow.triangle.2.circlepath"
        case .unchecked: return "questionmark.circle"
        }
    }
}

struct TaskStepBadge: View {
    let title: String
    let result: TaskStepResult

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: iconName)
            Text("\(title) \(result.displayName)")
        }
        .font(.caption2.weight(.medium))
        .foregroundStyle(color)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(color.opacity(0.12))
        .clipShape(Capsule())
    }

    private var color: Color {
        switch result {
        case .succeeded: return .green
        case .failed: return .red
        case .running: return .blue
        case .pending: return .orange
        case .skipped: return .secondary
        }
    }

    private var iconName: String {
        switch result {
        case .succeeded: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        case .running: return "arrow.triangle.2.circlepath"
        case .pending: return "clock"
        case .skipped: return "minus.circle"
        }
    }
}

struct QueueTaskRow: View {
    let item: DownloadQueueItem
    let coverPath: String
    let isSelected: Bool
    let onSelect: () -> Void
    let onRetry: () -> Void
    let onRetryScrape: () -> Void
    let onRetryScrapeWithCurrentSource: () -> Void
    let onPreview: () -> Void
    let onCancel: () -> Void
    let onDelete: () -> Void
    let onMoveFirst: () -> Void
    let onOpen: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: onSelect) {
                HStack(alignment: .top, spacing: 10) {
                    TaskCoverThumbnail(path: coverPath)
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(item.state.displayName)
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(stateColor.opacity(0.16))
                                .foregroundStyle(stateColor)
                                .clipShape(Capsule())
                            Text(item.displayTitle)
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(1)
                            Spacer()
                            Text("线程 \(item.threadCount)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        ProgressView(value: item.progress)
                            .progressViewStyle(.linear)
                        HStack(spacing: 5) {
                            TaskStepBadge(title: "1 下载", result: item.downloadStepResult ?? .pending)
                            TaskStepBadge(title: "2 刮削", result: item.scrapeStepResult ?? .pending)
                            TaskStepBadge(title: "3 NAS", result: item.nasStepResult ?? .pending)
                            Spacer()
                            Text(sizeText)
                                .font(.caption)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                            Text("·")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                            Text("\(Int(item.progress * 100))%")
                                .font(.caption)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            HStack(spacing: 6) {
                if item.state == .pending {
                    Button("优先") { onMoveFirst() }
                    Button("取消") { onCancel() }
                } else if !item.state.isFinished {
                    Button("停止") { onCancel() }
                }
                if [.failed, .cancelled, .interrupted].contains(item.state) {
                    Button("重试") { onRetry() }
                }
                if item.state.isFinished && item.resultMessage.contains("刮削未匹配") {
                    Button("重试刮削") { onRetryScrape() }
                    Button("换源重试") { onRetryScrapeWithCurrentSource() }
                }
                if item.state.isFinished && item.organizeAfterDownload && !item.outputPath.isEmpty {
                    Button("刮削预览") { onPreview() }
                }
                if !item.outputPath.isEmpty {
                    Button("打开结果") { onOpen() }
                }
                Spacer()
                if item.state.isFinished {
                    Button("删除记录", role: .destructive) { onDelete() }
                }
            }
            .font(.caption)
            .buttonStyle(.borderless)
        }
        .padding(8)
        .background(isSelected ? Color.accentColor.opacity(0.11) : Color.white.opacity(0.62))
        .overlay(
            RoundedRectangle(cornerRadius: 9)
                .stroke(isSelected ? Color.accentColor.opacity(0.55) : Color.clear, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 9))
    }

    private var stateColor: Color {
        switch item.state {
        case .completed, .skipped: return .green
        case .failed, .cancelled, .interrupted: return .red
        case .pending: return .secondary
        case .awaitingReview: return .blue
        case .nasTransferring: return .blue
        default: return .orange
        }
    }

    private var sizeText: String {
        guard let total = item.totalBytes, total > 0 else {
            if let downloaded = item.downloadedBytes, downloaded > 0 {
                return ByteCountFormatter.string(fromByteCount: downloaded, countStyle: .binary)
            }
            return "大小未知"
        }
        let downloaded = item.downloadedBytes ?? 0
        return "\(ByteCountFormatter.string(fromByteCount: downloaded, countStyle: .binary)) / \(ByteCountFormatter.string(fromByteCount: total, countStyle: .binary))"
    }
}

struct TaskCoverThumbnail: View {
    let path: String

    var body: some View {
        Group {
            if !path.isEmpty, let image = NSImage(contentsOfFile: path) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    Color.secondary.opacity(0.1)
                    Image(systemName: "photo")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: 54, height: 76)
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.secondary.opacity(0.16)))
    }
}

@main
struct NM3U8DLREMacApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .defaultSize(width: 1240, height: 860)
        .windowResizability(.contentSize)
    }
}
