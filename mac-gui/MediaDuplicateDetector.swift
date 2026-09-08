import Foundation

enum MediaDuplicateDetector {
    private static let mediaExtensions = Set(["mp4", "mkv", "ts", "mov", "m4v", "webm"])

    static func findExistingMedia(
        saveDirectory: String,
        catalogNumber: String,
        saveName: String
    ) -> URL? {
        let catalog = MediaOrganizer.catalogNumber(from: catalogNumber)
            ?? MediaOrganizer.catalogNumber(from: saveName)
        guard let catalog else { return nil }

        let rootURL = URL(fileURLWithPath: saveDirectory, isDirectory: true)
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return nil }

        for case let url as URL in enumerator {
            guard mediaExtensions.contains(url.pathExtension.lowercased()),
                  let values = try? url.resourceValues(forKeys: keys),
                  values.isRegularFile == true,
                  (values.fileSize ?? 0) >= 1_000_000 else { continue }

            let stem = url.deletingPathExtension().lastPathComponent
            let parent = url.deletingLastPathComponent().lastPathComponent.uppercased()
            if parent == catalog || MediaOrganizer.catalogNumber(from: stem) == catalog {
                return url
            }
        }
        return nil
    }
}
