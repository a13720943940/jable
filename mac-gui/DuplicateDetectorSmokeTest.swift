import Foundation

@main
struct DuplicateDetectorSmokeTest {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("jable-duplicate-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let organized = root
            .appendingPathComponent("测试演员/TEST-123", isDirectory: true)
        try FileManager.default.createDirectory(at: organized, withIntermediateDirectories: true)
        let video = organized.appendingPathComponent("TEST-123.mp4")
        try Data(repeating: 1, count: 1_100_000).write(to: video)

        let found = MediaDuplicateDetector.findExistingMedia(
            saveDirectory: root.path,
            catalogNumber: "test-123",
            saveName: ""
        )
        precondition(found?.standardizedFileURL == video.standardizedFileURL)
        precondition(MediaDuplicateDetector.findExistingMedia(
            saveDirectory: root.path,
            catalogNumber: "OTHER-999",
            saveName: ""
        ) == nil)
        print("Duplicate detector smoke test passed")
    }
}
