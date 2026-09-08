import Foundation

@main
struct MediaOrganizerSmokeTest {
    static func main() async throws {
        precondition(MediaOrganizer.catalogNumber(from: "SAME-246 测试标题") == "SAME-246")
        precondition(MediaOrganizer.catalogNumber(from: "same 246 test") == "SAME-246")

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("jable-organizer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let oldFolder = root.appendingPathComponent("SAME-246 测试标题旧目录", isDirectory: true)
        try FileManager.default.createDirectory(at: oldFolder, withIntermediateDirectories: true)
        let source = oldFolder.appendingPathComponent("SAME-246 测试标题.mp4")
        try Data(repeating: 0, count: 1_100_000).write(to: source)
        let result = try await MediaOrganizer.organize(
            saveDirectory: root.path,
            requestedName: "SAME-246 测试标题",
            explicitCatalogNumber: "",
            explicitPerformerName: "测试演员",
            startedAt: Date().addingTimeInterval(-2),
            scraperDomains: [],
            sourceFile: source
        )

        precondition(result.mediaURL.lastPathComponent == "SAME-246.mp4")
        precondition(result.mediaURL.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent == "测试演员")
        precondition(result.performerName == "测试演员")
        precondition(FileManager.default.fileExists(atPath: result.mediaURL.path))
        precondition(FileManager.default.fileExists(atPath: result.folderURL.appendingPathComponent("SAME-246.nfo").path))
        precondition(FileManager.default.fileExists(atPath: result.folderURL.appendingPathComponent("metadata.json").path))
        precondition(!FileManager.default.fileExists(atPath: oldFolder.path))
        precondition(result.removedOriginalDirectories.contains(oldFolder))

        let edited = try MediaOrganizer.applyMetadataEdits(
            folderURL: result.folderURL,
            title: "修改后的标题",
            performerName: "新演员",
            releaseDate: "2026-08-17",
            description: "预览确认后的简介",
            keywords: ["标签一", "标签二"]
        )
        precondition(edited.folderURL.deletingLastPathComponent().lastPathComponent == "新演员")
        precondition(edited.metadata.title == "修改后的标题")
        precondition(edited.metadata.actress.keys.first == "新演员")
        precondition(FileManager.default.fileExists(atPath: edited.mediaURL.path))
        let editedNFO = try String(contentsOf: edited.folderURL.appendingPathComponent("SAME-246.nfo"), encoding: .utf8)
        precondition(editedNFO.contains("修改后的标题"))
        precondition(!FileManager.default.fileExists(atPath: result.folderURL.path))

        let sharedFolder = root.appendingPathComponent("MIDA-681 混合目录", isDirectory: true)
        try FileManager.default.createDirectory(at: sharedFolder, withIntermediateDirectories: true)
        let selected = sharedFolder.appendingPathComponent("MIDA-681.mp4")
        let otherVideo = sharedFolder.appendingPathComponent("OTHER-001.mp4")
        try Data(repeating: 0, count: 128).write(to: selected)
        try Data(repeating: 0, count: 128).write(to: otherVideo)
        let protectedResult = try await MediaOrganizer.organize(
            saveDirectory: root.path,
            requestedName: "MIDA-681",
            explicitCatalogNumber: "MIDA-681",
            explicitPerformerName: "另一演员",
            startedAt: .distantPast,
            scraperDomains: [],
            sourceFile: selected
        )
        precondition(FileManager.default.fileExists(atPath: sharedFolder.path))
        precondition(FileManager.default.fileExists(atPath: otherVideo.path))
        precondition(protectedResult.removedOriginalDirectories.isEmpty)

        let legacyTitle = "TEST-123 同级临时目录"
        let rootVideo = root.appendingPathComponent("\(legacyTitle).mp4")
        let siblingLegacyFolder = root.appendingPathComponent(legacyTitle, isDirectory: true)
        try Data(repeating: 0, count: 128).write(to: rootVideo)
        try FileManager.default.createDirectory(at: siblingLegacyFolder, withIntermediateDirectories: true)
        try Data().write(to: siblingLegacyFolder.appendingPathComponent(".DS_Store"))
        let siblingResult = try await MediaOrganizer.organize(
            saveDirectory: root.path,
            requestedName: legacyTitle,
            explicitCatalogNumber: "TEST-123",
            explicitPerformerName: "测试演员",
            startedAt: .distantPast,
            scraperDomains: [],
            sourceFile: rootVideo
        )
        precondition(!FileManager.default.fileExists(atPath: siblingLegacyFolder.path))
        precondition(siblingResult.removedOriginalDirectories.contains(siblingLegacyFolder))
        print("MediaOrganizer smoke test passed")
    }
}
