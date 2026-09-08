import AppKit
import Foundation

struct ScrapedMediaMetadata: Codable {
    var title: String
    var cover: String
    var avid: String
    var actress: [String: String]
    var description: String
    var duration: String
    var releaseDate: String
    var keywords: [String]
    var fanarts: [String]

    enum CodingKeys: String, CodingKey {
        case title, cover, avid, actress, description, duration, keywords, fanarts
        case releaseDate = "release_date"
    }
}

struct OrganizationResult {
    let folderURL: URL
    let mediaURL: URL
    let performerName: String
    let metadataFound: Bool
    let removedOriginalDirectories: [URL]
}

enum MediaOrganizerError: LocalizedError {
    case catalogNumberMissing
    case mediaFileMissing
    case destinationExists(String)
    case invalidMetadataResponse

    var errorDescription: String? {
        switch self {
        case .catalogNumberMissing:
            return "无法从标题中识别番号，请手动填写番号。"
        case .mediaFileMissing:
            return "下载已完成，但没有找到本次生成的视频文件。"
        case .destinationExists(let path):
            return "整理目标已经存在，为避免覆盖已跳过：\(path)"
        case .invalidMetadataResponse:
            return "元数据页面内容无法识别。"
        }
    }
}

enum MediaOrganizer {
    private static let mediaExtensions = Set(["mp4", "mkv", "ts", "mov", "m4v", "webm"])

    static func catalogNumber(from text: String) -> String? {
        let pattern = #"(?i)(?:^|[^A-Z0-9])([A-Z]{2,12})[-_\s]?(\d{2,5})(?:[^A-Z0-9]|$)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                in: text,
                range: NSRange(text.startIndex..<text.endIndex, in: text)
              ),
              let prefixRange = Range(match.range(at: 1), in: text),
              let numberRange = Range(match.range(at: 2), in: text) else {
            return nil
        }
        return "\(text[prefixRange].uppercased())-\(text[numberRange])"
    }

    static func locateDownloadedMedia(
        saveDirectory: String,
        requestedName: String,
        catalogNumber explicitCatalogNumber: String,
        startedAt: Date
    ) -> URL? {
        let catalog = normalizedCatalogNumber(explicitCatalogNumber)
            ?? catalogNumber(from: requestedName)
            ?? ""
        return findDownloadedMedia(
            in: URL(fileURLWithPath: saveDirectory, isDirectory: true),
            requestedName: requestedName,
            catalog: catalog,
            startedAt: startedAt
        )
    }

    static func loadMetadata(from folderURL: URL) throws -> ScrapedMediaMetadata {
        let data = try Data(contentsOf: folderURL.appendingPathComponent("metadata.json"))
        return try JSONDecoder().decode(ScrapedMediaMetadata.self, from: data)
    }

    static func applyMetadataEdits(
        folderURL: URL,
        title: String,
        performerName: String,
        releaseDate: String,
        description: String,
        keywords: [String]
    ) throws -> (folderURL: URL, mediaURL: URL, metadata: ScrapedMediaMetadata) {
        var metadata = try loadMetadata(from: folderURL)
        metadata.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        metadata.releaseDate = releaseDate.trimmingCharacters(in: .whitespacesAndNewlines)
        metadata.description = description.trimmingCharacters(in: .whitespacesAndNewlines)
        metadata.keywords = keywords

        let performer = normalizedPathComponent(performerName) ?? "未知演员"
        let existingAvatar = metadata.actress.values.first ?? ""
        metadata.actress = performer == "未知演员" ? [:] : [performer: existingAvatar]

        let catalog = normalizedCatalogNumber(metadata.avid) ?? folderURL.lastPathComponent
        let rootURL = folderURL.deletingLastPathComponent().deletingLastPathComponent()
        let destinationFolder = rootURL
            .appendingPathComponent(performer, isDirectory: true)
            .appendingPathComponent(catalog, isDirectory: true)
        var finalFolder = folderURL
        if destinationFolder.standardizedFileURL != folderURL.standardizedFileURL {
            guard !FileManager.default.fileExists(atPath: destinationFolder.path) else {
                throw MediaOrganizerError.destinationExists(destinationFolder.path)
            }
            try FileManager.default.createDirectory(
                at: destinationFolder.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try FileManager.default.moveItem(at: folderURL, to: destinationFolder)
            let oldPerformerFolder = folderURL.deletingLastPathComponent()
            if (try? FileManager.default.contentsOfDirectory(atPath: oldPerformerFolder.path).isEmpty) == true {
                try? FileManager.default.removeItem(at: oldPerformerFolder)
            }
            finalFolder = destinationFolder
        }
        try writeMetadata(metadata, to: finalFolder)
        try writeNFO(metadata, to: finalFolder)
        guard let mediaURL = firstMediaFile(in: finalFolder) else { throw MediaOrganizerError.mediaFileMissing }
        return (finalFolder, mediaURL, metadata)
    }

    static func firstMediaFile(in folderURL: URL) -> URL? {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: folderURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        return contents.first { mediaExtensions.contains($0.pathExtension.lowercased()) }
    }

    static func organize(
        saveDirectory: String,
        requestedName: String,
        explicitCatalogNumber: String,
        explicitPerformerName: String = "",
        startedAt: Date,
        scraperDomains: [String],
        sourceFile: URL? = nil,
        progress: @escaping @MainActor (Double, String) -> Void = { _, _ in }
    ) async throws -> OrganizationResult {
        await progress(0.05, "正在识别番号")
        let catalog = normalizedCatalogNumber(explicitCatalogNumber)
            ?? catalogNumber(from: requestedName)
        guard let catalog else { throw MediaOrganizerError.catalogNumberMissing }

        let rootURL = URL(fileURLWithPath: saveDirectory, isDirectory: true)
        await progress(0.12, "正在定位视频文件")
        guard let sourceURL = sourceFile ?? findDownloadedMedia(
                in: rootURL,
                requestedName: requestedName,
                catalog: catalog,
                startedAt: startedAt
              ),
              FileManager.default.fileExists(atPath: sourceURL.path),
              mediaExtensions.contains(sourceURL.pathExtension.lowercased()) else {
            throw MediaOrganizerError.mediaFileMissing
        }

        await progress(0.24, "正在请求影片元数据")
        let scraped = await scrape(catalog: catalog, domains: scraperDomains)
        let metadata = scraped?.metadata ?? ScrapedMediaMetadata(
            title: requestedName.isEmpty ? catalog : requestedName,
            cover: "",
            avid: catalog,
            actress: [:],
            description: "",
            duration: "",
            releaseDate: "",
            keywords: [],
            fanarts: []
        )

        let performerName = normalizedPathComponent(explicitPerformerName)
            ?? metadata.actress.keys.sorted().compactMap(normalizedPathComponent).first
            ?? "未知演员"
        let performerFolderURL = rootURL.appendingPathComponent(performerName, isDirectory: true)
        let folderURL = performerFolderURL.appendingPathComponent(catalog, isDirectory: true)
        let originalDirectory = originalTopLevelDirectory(
            containing: sourceURL,
            under: rootURL,
            excluding: folderURL
        )
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        let destinationURL = folderURL.appendingPathComponent("\(catalog).\(sourceURL.pathExtension.lowercased())")

        await progress(0.48, "正在整理到演员目录")
        if sourceURL.standardizedFileURL != destinationURL.standardizedFileURL {
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                throw MediaOrganizerError.destinationExists(destinationURL.path)
            }
            try FileManager.default.moveItem(at: sourceURL, to: destinationURL)
        }

        await progress(0.64, scraped == nil ? "生成基础元数据" : "正在生成元数据与 NFO")
        try writeMetadata(metadata, to: folderURL)
        try writeNFO(metadata, to: folderURL)

        if let scraped {
            await progress(0.76, "正在下载封面与海报")
            await downloadArtwork(metadata: metadata, pageURL: scraped.pageURL, folderURL: folderURL)
        }

        await progress(0.92, "正在清理原目录")
        let legacyTitleDirectory = requestedName.isEmpty
            ? nil
            : rootURL.appendingPathComponent(requestedName, isDirectory: true)
        let cleanupCandidates = [originalDirectory, legacyTitleDirectory]
            .compactMap { $0 }
            .filter { candidate in
                let candidatePath = candidate.standardizedFileURL.path
                let destinationPath = folderURL.standardizedFileURL.path
                return candidatePath != destinationPath && !destinationPath.hasPrefix(candidatePath + "/")
            }
        var removedOriginalDirectories: [URL] = []
        for candidate in cleanupCandidates where !removedOriginalDirectories.contains(candidate) {
            if let removed = removeOriginalDirectoryIfSafe(candidate) {
                removedOriginalDirectories.append(removed)
            }
        }
        await progress(1, "刮削整理完成")

        return OrganizationResult(
            folderURL: folderURL,
            mediaURL: destinationURL,
            performerName: performerName,
            metadataFound: scraped != nil,
            removedOriginalDirectories: removedOriginalDirectories
        )
    }

    private static func originalTopLevelDirectory(
        containing sourceURL: URL,
        under rootURL: URL,
        excluding destinationFolder: URL
    ) -> URL? {
        let rootPath = rootURL.standardizedFileURL.path
        let sourcePath = sourceURL.standardizedFileURL.path
        guard sourcePath.hasPrefix(rootPath + "/") else { return nil }
        let relativePath = String(sourcePath.dropFirst(rootPath.count + 1))
        guard let firstComponent = relativePath.split(separator: "/").first,
              relativePath.contains("/") else { return nil }
        let candidate = rootURL.appendingPathComponent(String(firstComponent), isDirectory: true)
        let candidatePath = candidate.standardizedFileURL.path
        let destinationPath = destinationFolder.standardizedFileURL.path
        guard destinationPath != candidatePath,
              !destinationPath.hasPrefix(candidatePath + "/") else { return nil }
        return candidate
    }

    private static func normalizedPathComponent(_ value: String) -> String? {
        let forbidden = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        let cleaned = value.components(separatedBy: forbidden).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard !cleaned.isEmpty else { return nil }
        return String(cleaned.prefix(80))
    }

    private static func removeOriginalDirectoryIfSafe(_ directoryURL: URL?) -> URL? {
        guard let directoryURL,
              FileManager.default.fileExists(atPath: directoryURL.path),
              let enumerator = FileManager.default.enumerator(
                at: directoryURL,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
              ) else { return nil }

        for case let url as URL in enumerator {
            if mediaExtensions.contains(url.pathExtension.lowercased()) {
                return nil
            }
        }

        do {
            try FileManager.default.removeItem(at: directoryURL)
            return directoryURL
        } catch {
            return nil
        }
    }

    private static func normalizedCatalogNumber(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return catalogNumber(from: trimmed) ?? trimmed.uppercased()
    }

    private static func findDownloadedMedia(
        in rootURL: URL,
        requestedName: String,
        catalog: String,
        startedAt: Date
    ) -> URL? {
        let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return nil }

        let requested = requestedName.lowercased()
        let catalogLower = catalog.lowercased()
        var candidates: [(url: URL, score: Int, modified: Date)] = []

        for case let url as URL in enumerator {
            guard mediaExtensions.contains(url.pathExtension.lowercased()),
                  let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true,
                  let modified = values.contentModificationDate,
                  modified >= startedAt.addingTimeInterval(-30) else { continue }

            let stem = url.deletingPathExtension().lastPathComponent.lowercased()
            var score = 0
            if !requested.isEmpty && stem == requested { score += 100 }
            if !requested.isEmpty && stem.contains(requested) { score += 40 }
            if stem.contains(catalogLower) { score += 60 }
            if (values.fileSize ?? 0) > 1_000_000 { score += 10 }
            candidates.append((url, score, modified))
        }

        return candidates.sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            return $0.modified > $1.modified
        }.first?.url
    }

    private static func scrape(
        catalog: String,
        domains: [String]
    ) async -> (metadata: ScrapedMediaMetadata, pageURL: URL)? {
        for rawDomain in domains {
            let domain = rawDomain
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "https://", with: "")
                .replacingOccurrences(of: "http://", with: "")
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !domain.isEmpty,
                  let pageURL = URL(string: "https://\(domain)/\(catalog)") else { continue }

            var request = URLRequest(url: pageURL, timeoutInterval: 18)
            request.setValue(
                "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 Chrome/124 Safari/537.36",
                forHTTPHeaderField: "User-Agent"
            )
            request.setValue("zh-CN,zh;q=0.9,en;q=0.7", forHTTPHeaderField: "Accept-Language")
            request.setValue("age=verified; existmag=mag", forHTTPHeaderField: "Cookie")

            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  let httpResponse = response as? HTTPURLResponse,
                  (200..<300).contains(httpResponse.statusCode),
                  let html = String(data: data, encoding: .utf8),
                  let metadata = parseMetadata(html: html, pageURL: pageURL, fallbackCatalog: catalog) else {
                continue
            }
            return (metadata, pageURL)
        }
        return nil
    }

    private static func parseMetadata(
        html: String,
        pageURL: URL,
        fallbackCatalog: String
    ) -> ScrapedMediaMetadata? {
        let rawTitle = firstMatch(#"<title>\s*(.*?)\s*(?:-\s*JavBus)?\s*</title>"#, in: html)
        let rawCover = firstMatch(#"<a[^>]*class=[\"'][^\"']*bigImage[^\"']*[\"'][^>]*href=[\"']([^\"']+)[\"']"#, in: html)
        guard let rawTitle, let rawCover else { return nil }

        let detectedCatalog = catalogNumber(from: decodeHTML(rawTitle)) ?? fallbackCatalog
        let title = decodeHTML(rawTitle)
            .replacingOccurrences(of: " - JavBus", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let description = decodeHTML(metaContent(named: "description", in: html) ?? "")
        let keywords = decodeHTML(metaContent(named: "keywords", in: html) ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let releaseDate = firstMatch(#"<span[^>]*class=[\"']header[\"'][^>]*>\s*發行日期:\s*</span>\s*([^<]+)"#, in: html)
            .map(decodeHTML) ?? ""
        let duration = firstMatch(#"<span[^>]*class=[\"']header[\"'][^>]*>\s*長度:\s*</span>\s*([^<]+)"#, in: html)
            .map(decodeHTML) ?? ""

        let cover = absoluteURLString(rawCover, relativeTo: pageURL)
        let fanarts = allMatches(#"<a[^>]*class=[\"'][^\"']*sample-box[^\"']*[\"'][^>]*href=[\"']([^\"']+\.jpg[^\"']*)[\"']"#, in: html)
            .map { absoluteURLString($0, relativeTo: pageURL) }
        let actorMatches = pairedMatches(
            #"<a[^>]*class=[\"'][^\"']*avatar-box[^\"']*[\"'][^>]*>.*?<img[^>]*src=[\"']([^\"']+)[\"'][^>]*>.*?<span[^>]*>([^<]+)</span>"#,
            in: html
        )
        var actresses: [String: String] = [:]
        for pair in actorMatches {
            actresses[decodeHTML(pair.1)] = absoluteURLString(pair.0, relativeTo: pageURL)
        }

        return ScrapedMediaMetadata(
            title: title,
            cover: cover,
            avid: detectedCatalog,
            actress: actresses,
            description: description,
            duration: duration.trimmingCharacters(in: .whitespacesAndNewlines),
            releaseDate: releaseDate.trimmingCharacters(in: .whitespacesAndNewlines),
            keywords: keywords,
            fanarts: fanarts
        )
    }

    private static func writeMetadata(_ metadata: ScrapedMediaMetadata, to folderURL: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(metadata)
        try data.write(to: folderURL.appendingPathComponent("metadata.json"), options: .atomic)
    }

    private static func writeNFO(_ metadata: ScrapedMediaMetadata, to folderURL: URL) throws {
        var lines = [
            "<?xml version=\"1.0\" encoding=\"UTF-8\"?>",
            "<movie>",
            "  <title>\(xmlEscaped(metadata.title))</title>",
            "  <originaltitle>\(xmlEscaped(metadata.avid))</originaltitle>",
            "  <plot>\(xmlEscaped(metadata.description))</plot>",
            "  <outline>\(xmlEscaped(String(metadata.description.prefix(100))))</outline>"
        ]
        if !metadata.releaseDate.isEmpty {
            lines.append("  <premiered>\(xmlEscaped(metadata.releaseDate))</premiered>")
            lines.append("  <releasedate>\(xmlEscaped(metadata.releaseDate))</releasedate>")
        }
        if let runtime = firstMatch(#"(\d+)"#, in: metadata.duration) {
            lines.append("  <runtime>\(runtime)</runtime>")
        }
        if !metadata.cover.isEmpty {
            lines.append("  <art>")
            lines.append("    <poster>\(metadata.avid)-poster.jpg</poster>")
            lines.append("    <fanart>\(metadata.avid)-fanart.jpg</fanart>")
            lines.append("  </art>")
        }
        for name in metadata.actress.keys.sorted() {
            lines.append("  <actor><name>\(xmlEscaped(name))</name></actor>")
        }
        for keyword in metadata.keywords.prefix(5) {
            lines.append("  <genre>\(xmlEscaped(keyword))</genre>")
        }
        lines.append("</movie>")
        try lines.joined(separator: "\n").write(
            to: folderURL.appendingPathComponent("\(metadata.avid).nfo"),
            atomically: true,
            encoding: .utf8
        )
    }

    private static func downloadArtwork(
        metadata: ScrapedMediaMetadata,
        pageURL: URL,
        folderURL: URL
    ) async {
        guard let coverURL = URL(string: metadata.cover),
              let coverData = await downloadImage(coverURL, referer: pageURL) else { return }
        let fanartURL = folderURL.appendingPathComponent("\(metadata.avid)-fanart.jpg")
        try? coverData.write(to: fanartURL, options: .atomic)
        writePoster(from: coverData, to: folderURL.appendingPathComponent("\(metadata.avid)-poster.jpg"))

        for (offset, urlString) in metadata.fanarts.prefix(8).enumerated() {
            guard let url = URL(string: urlString),
                  let data = await downloadImage(url, referer: pageURL) else { continue }
            try? data.write(
                to: folderURL.appendingPathComponent("\(metadata.avid)-fanart-\(offset + 2).jpg"),
                options: .atomic
            )
        }
    }

    private static func downloadImage(_ url: URL, referer: URL) async -> Data? {
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 Chrome/124 Safari/537.36", forHTTPHeaderField: "User-Agent")
        request.setValue(referer.absoluteString, forHTTPHeaderField: "Referer")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode),
              NSImage(data: data) != nil else { return nil }
        return data
    }

    private static func writePoster(from data: Data, to destinationURL: URL) {
        guard let image = NSImage(data: data),
              let source = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        let targetWidth = min(source.width, Int(Double(source.height) * 565.0 / 800.0))
        let cropRect = CGRect(x: source.width - targetWidth, y: 0, width: targetWidth, height: source.height)
        guard let cropped = source.cropping(to: cropRect) else { return }
        let representation = NSBitmapImageRep(cgImage: cropped)
        guard let jpeg = representation.representation(using: .jpeg, properties: [.compressionFactor: 0.92]) else { return }
        try? jpeg.write(to: destinationURL, options: .atomic)
    }

    private static func metaContent(named name: String, in html: String) -> String? {
        firstMatch(#"<meta[^>]*name=[\"']"# + NSRegularExpression.escapedPattern(for: name) + #"[\"'][^>]*content=[\"']([^\"']*)[\"']"#, in: html)
            ?? firstMatch(#"<meta[^>]*content=[\"']([^\"']*)[\"'][^>]*name=[\"']"# + NSRegularExpression.escapedPattern(for: name) + #"[\"']"#, in: html)
    }

    private static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    private static func allMatches(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text)).compactMap {
            guard $0.numberOfRanges > 1, let range = Range($0.range(at: 1), in: text) else { return nil }
            return String(text[range])
        }
    }

    private static func pairedMatches(_ pattern: String, in text: String) -> [(String, String)] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text)).compactMap {
            guard $0.numberOfRanges > 2,
                  let first = Range($0.range(at: 1), in: text),
                  let second = Range($0.range(at: 2), in: text) else { return nil }
            return (String(text[first]), String(text[second]))
        }
    }

    private static func absoluteURLString(_ value: String, relativeTo pageURL: URL) -> String {
        URL(string: decodeHTML(value), relativeTo: pageURL)?.absoluteURL.absoluteString ?? value
    }

    private static func decodeHTML(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&nbsp;", with: " ")
    }

    private static func xmlEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}
