import Foundation

struct NASTransferResult {
    let destinationURL: URL
    let bytesTransferred: Int64
}

struct NASTransferProgress: Sendable {
    let fraction: Double
    let transferredBytes: Int64
    let totalBytes: Int64
    let bytesPerSecond: Double
    let estimatedRemaining: TimeInterval?
    let phase: String
}

enum NASTransferError: LocalizedError {
    case sourceMissing
    case destinationUnavailable(String)
    case destinationExists(String)
    case verificationFailed(String)

    var errorDescription: String? {
        switch self {
        case .sourceMissing:
            return "本地整理目录不存在。"
        case .destinationUnavailable(let path):
            return "NAS 目标路径不可用，请先连接 NAS：\(path)"
        case .destinationExists(let path):
            return "NAS 中已存在同名目录，为避免覆盖已停止：\(path)"
        case .verificationFailed(let path):
            return "NAS 文件校验失败：\(path)"
        }
    }
}

enum NASTransfer {
    static func transfer(
        sourceFolder: URL,
        destinationRoot: URL,
        performerName: String,
        catalogNumber: String,
        moveAfterTransfer: Bool,
        progress: @escaping @MainActor (NASTransferProgress) -> Void
    ) async throws -> NASTransferResult {
        try await Task.detached(priority: .utility) {
            let manager = FileManager.default
            var isDirectory: ObjCBool = false
            guard manager.fileExists(atPath: sourceFolder.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw NASTransferError.sourceMissing
            }
            guard manager.fileExists(atPath: destinationRoot.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw NASTransferError.destinationUnavailable(destinationRoot.path)
            }

            let performerFolder = destinationRoot.appendingPathComponent(performerName, isDirectory: true)
            let destinationFolder = performerFolder.appendingPathComponent(catalogNumber, isDirectory: true)
            if manager.fileExists(atPath: destinationFolder.path) {
                throw NASTransferError.destinationExists(destinationFolder.path)
            }

            let files = try regularFiles(in: sourceFolder)
            let totalBytes = files.reduce(Int64(0)) { $0 + $1.size }
            try manager.createDirectory(at: destinationFolder, withIntermediateDirectories: true)
            var copiedBytes: Int64 = 0
            let transferStartedAt = Date()

            do {
                for file in files {
                    let sourceComponents = sourceFolder.standardizedFileURL.pathComponents
                    let fileComponents = file.url.standardizedFileURL.pathComponents
                    let relativeComponents = fileComponents.dropFirst(sourceComponents.count)
                    let destination = relativeComponents.reduce(destinationFolder) { partial, component in
                        partial.appendingPathComponent(component)
                    }
                    try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                    await progress(makeProgress(
                        completedBytes: copiedBytes,
                        totalBytes: totalBytes,
                        startedAt: transferStartedAt,
                        phase: "发送 \(file.url.lastPathComponent)"
                    ))
                    copiedBytes += try await copyFile(
                        source: file.url,
                        destination: destination,
                        alreadyCopied: copiedBytes,
                        totalBytes: totalBytes,
                        transferStartedAt: transferStartedAt,
                        progress: progress
                    )
                    let destinationSize = try destination.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? -1
                    if Int64(destinationSize) != file.size {
                        throw NASTransferError.verificationFailed(destination.path)
                    }
                }
            } catch {
                try? manager.removeItem(at: destinationFolder)
                throw error
            }

            await progress(makeProgress(
                completedBytes: copiedBytes,
                totalBytes: totalBytes,
                startedAt: transferStartedAt,
                phase: "NAS 发送完成"
            ))
            if moveAfterTransfer {
                try manager.removeItem(at: sourceFolder)
                removeEmptyParents(startingAt: sourceFolder.deletingLastPathComponent(), stopAt: sourceFolder.deletingLastPathComponent().deletingLastPathComponent())
            }
            return NASTransferResult(destinationURL: destinationFolder, bytesTransferred: copiedBytes)
        }.value
    }

    private static func regularFiles(in folder: URL) throws -> [(url: URL, size: Int64)] {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(
            at: folder,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }
        return try enumerator.compactMap { item in
            guard let url = item as? URL else { return nil }
            let values = try url.resourceValues(forKeys: keys)
            guard values.isRegularFile == true else { return nil }
            return (url, Int64(values.fileSize ?? 0))
        }
    }

    private static func copyFile(
        source: URL,
        destination: URL,
        alreadyCopied: Int64,
        totalBytes: Int64,
        transferStartedAt: Date,
        progress: @escaping @MainActor (NASTransferProgress) -> Void
    ) async throws -> Int64 {
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let input = try FileHandle(forReadingFrom: source)
        let output = try FileHandle(forWritingTo: destination)
        defer {
            try? input.close()
            try? output.close()
        }
        var fileBytes: Int64 = 0
        while true {
            let data = try input.read(upToCount: 4 * 1_024 * 1_024) ?? Data()
            if data.isEmpty { break }
            try output.write(contentsOf: data)
            fileBytes += Int64(data.count)
            let completed = alreadyCopied + fileBytes
            await progress(makeProgress(
                completedBytes: completed,
                totalBytes: totalBytes,
                startedAt: transferStartedAt,
                phase: "正在发送到 NAS"
            ))
        }
        try output.synchronize()
        return fileBytes
    }

    private static func makeProgress(
        completedBytes: Int64,
        totalBytes: Int64,
        startedAt: Date,
        phase: String
    ) -> NASTransferProgress {
        let elapsed = max(Date().timeIntervalSince(startedAt), 0.001)
        let speed = Double(completedBytes) / elapsed
        let remainingBytes = max(totalBytes - completedBytes, 0)
        let remaining = speed > 0 ? Double(remainingBytes) / speed : nil
        return NASTransferProgress(
            fraction: totalBytes > 0 ? min(Double(completedBytes) / Double(totalBytes), 1) : 1,
            transferredBytes: completedBytes,
            totalBytes: totalBytes,
            bytesPerSecond: speed,
            estimatedRemaining: remaining,
            phase: phase
        )
    }

    private static func removeEmptyParents(startingAt directory: URL, stopAt: URL) {
        var current = directory
        while current.path != stopAt.path {
            guard let contents = try? FileManager.default.contentsOfDirectory(atPath: current.path), contents.isEmpty else { return }
            try? FileManager.default.removeItem(at: current)
            current.deleteLastPathComponent()
        }
    }
}
