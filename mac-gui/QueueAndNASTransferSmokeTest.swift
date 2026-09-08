import Foundation

@main
struct QueueAndNASTransferSmokeTest {
    @MainActor
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("jable-queue-nas-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = try QueueStore(databaseURL: root.appendingPathComponent("queue.sqlite3"))
        let item = DownloadQueueItem(
            id: UUID(),
            inputURL: "https://example.com/test.m3u8",
            saveDirectory: root.path,
            saveName: "TEST-001",
            extraArgs: "",
            catalogNumber: "TEST-001",
            performerName: "测试演员",
            scraperDomain: "example.com",
            scraperDomains: ["example.com", "backup.example.com"],
            previewBeforeCompletion: true,
            organizeAfterDownload: true,
            threadCount: 2,
            allowDuplicateDownload: false,
            nasEnabled: true,
            nasServerURL: "smb://nas/Media",
            nasDestinationPath: root.appendingPathComponent("nas").path,
            nasScrapeFailureEnabled: true,
            nasScrapeFailurePath: root.appendingPathComponent("nas-failed").path,
            nasLastTransferPath: nil,
            nasMoveAfterTransfer: false,
            downloadStepResult: .pending,
            scrapeStepResult: .pending,
            nasStepResult: .pending,
            downloadedBytes: nil,
            totalBytes: nil,
            scrapeMetadataFound: nil,
            reviewFolderPath: nil,
            state: .pending,
            progress: 0,
            phase: "等待执行",
            resultMessage: "",
            outputPath: "",
            logText: "已加入",
            createdAt: Date(),
            startedAt: nil,
            finishedAt: nil
        )
        try store.saveTask(item)
        let loadedTasks = try store.loadTasks()
        precondition(loadedTasks == [item])
        precondition(loadedTasks.first?.nasScrapeFailureEnabled == true)
        let settings = QueueSettings(
            downloadThreadCount: 2,
            allowDuplicateDownload: false,
            previewBeforeCompletion: true,
            scraperSources: [
                ScraperSource(id: UUID(), domain: "example.com", enabled: true, health: .available)
            ],
            nasEnabled: true,
            nasServerURL: "smb://nas/Media",
            nasDestinationPath: root.appendingPathComponent("nas").path,
            nasScrapeFailureEnabled: true,
            nasScrapeFailurePath: root.appendingPathComponent("nas-failed").path,
            nasMoveAfterTransfer: false
        )
        try store.saveSettings(settings)
        precondition(store.loadSettings().downloadThreadCount == 2)
        precondition(store.loadSettings().nasScrapeFailureEnabled == true)
        precondition(store.loadSettings().previewBeforeCompletion == true)
        precondition(store.loadSettings().scraperSources?.first?.domain == "example.com")

        let encodedItem = try JSONEncoder().encode(item)
        var legacyObject = try JSONSerialization.jsonObject(with: encodedItem) as! [String: Any]
        legacyObject.removeValue(forKey: "nasScrapeFailureEnabled")
        legacyObject.removeValue(forKey: "nasLastTransferPath")
        legacyObject.removeValue(forKey: "downloadStepResult")
        legacyObject.removeValue(forKey: "scrapeStepResult")
        legacyObject.removeValue(forKey: "nasStepResult")
        legacyObject.removeValue(forKey: "downloadedBytes")
        legacyObject.removeValue(forKey: "totalBytes")
        legacyObject.removeValue(forKey: "scraperDomains")
        legacyObject.removeValue(forKey: "previewBeforeCompletion")
        legacyObject.removeValue(forKey: "scrapeMetadataFound")
        legacyObject.removeValue(forKey: "reviewFolderPath")
        let legacyData = try JSONSerialization.data(withJSONObject: legacyObject)
        let migratedItem = try JSONDecoder().decode(DownloadQueueItem.self, from: legacyData)
        precondition(migratedItem.nasScrapeFailureEnabled == nil)
        precondition(migratedItem.downloadStepResult == nil)
        precondition(migratedItem.previewBeforeCompletion == nil)
        try store.deleteTask(id: item.id)
        let tasksAfterDelete = try store.loadTasks()
        precondition(tasksAfterDelete.isEmpty)

        let nasRoot = root.appendingPathComponent("nas", isDirectory: true)
        try FileManager.default.createDirectory(at: nasRoot, withIntermediateDirectories: true)
        precondition(NASMountSupport.prepareAndTestPath(nasRoot.path))
        let inferredURL = NASMountSupport.reconnectURL(
            serverURL: "smb://192.168.2.50",
            destinationPath: "/Volumes/观影/new/news9kg"
        )
        precondition(inferredURL?.host == "192.168.2.50")
        precondition(inferredURL?.path == "/观影")
        let localFolder = root
            .appendingPathComponent("local/测试演员/TEST-001", isDirectory: true)
        try FileManager.default.createDirectory(at: localFolder, withIntermediateDirectories: true)
        let video = Data(repeating: 7, count: 2_200_000)
        try video.write(to: localFolder.appendingPathComponent("TEST-001.mp4"))
        try Data("<movie/>".utf8).write(to: localFolder.appendingPathComponent("TEST-001.nfo"))

        var progressSamples: [NASTransferProgress] = []
        let copyResult = try await NASTransfer.transfer(
            sourceFolder: localFolder,
            destinationRoot: nasRoot,
            performerName: "测试演员",
            catalogNumber: "TEST-001",
            moveAfterTransfer: false
        ) { progressSamples.append($0) }
        precondition(FileManager.default.fileExists(atPath: localFolder.path))
        precondition(FileManager.default.fileExists(atPath: copyResult.destinationURL.appendingPathComponent("TEST-001.mp4").path))
        precondition(copyResult.bytesTransferred == Int64(video.count + "<movie/>".utf8.count))
        precondition(progressSamples.last?.fraction == 1)
        precondition(progressSamples.contains { $0.bytesPerSecond > 0 })

        let moveFolder = root
            .appendingPathComponent("local/另一演员/TEST-002", isDirectory: true)
        try FileManager.default.createDirectory(at: moveFolder, withIntermediateDirectories: true)
        try Data(repeating: 3, count: 128_000).write(to: moveFolder.appendingPathComponent("TEST-002.mp4"))
        let moveResult = try await NASTransfer.transfer(
            sourceFolder: moveFolder,
            destinationRoot: nasRoot,
            performerName: "另一演员",
            catalogNumber: "TEST-002",
            moveAfterTransfer: true
        ) { _ in }
        precondition(!FileManager.default.fileExists(atPath: moveFolder.path))
        precondition(FileManager.default.fileExists(atPath: moveResult.destinationURL.appendingPathComponent("TEST-002.mp4").path))
        print("Queue and NAS transfer smoke tests passed")
    }
}
