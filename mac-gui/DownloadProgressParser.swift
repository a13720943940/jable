import Foundation

struct DownloadProgressMetrics {
    let progressPercentage: Double?
    let speedText: String?
    let downloadedBytes: Int64?
    let totalBytes: Int64?
}

enum DownloadProgressParser {
    static func parse(_ text: String) -> DownloadProgressMetrics {
        let sizes = lastCaptureGroups(
            in: text,
            pattern: #"([0-9]+(?:\.[0-9]+)?\s*(?:[KMGT]i?B|[KMGT]B|B))\s*/\s*([0-9]+(?:\.[0-9]+)?\s*(?:[KMGT]i?B|[KMGT]B|B))"#,
            captureCount: 2,
            caseInsensitive: true
        )
        let speed = lastCaptureGroups(
            in: text,
            pattern: #"([0-9]+(?:\.[0-9]+)?\s*(?:[KMGT]i?B|[KMGT]B|B)(?:/s|ps))"#,
            captureCount: 1,
            caseInsensitive: false
        )?.first.map(normalizeSpeed)
        let percentage = lastCaptureGroups(
            in: text,
            pattern: #"([0-9]+(?:\.[0-9]+)?)%"#,
            captureCount: 1,
            caseInsensitive: false
        )?.first.flatMap(Double.init)
        return DownloadProgressMetrics(
            progressPercentage: percentage,
            speedText: speed,
            downloadedBytes: sizes.flatMap { parseByteCount($0[0]) },
            totalBytes: sizes.flatMap { parseByteCount($0[1]) }
        )
    }

    private static func normalizeSpeed(_ value: String) -> String {
        let compact = value.replacingOccurrences(of: " ", with: "")
        return compact.hasSuffix("Bps") ? String(compact.dropLast(2)) + "/s" : compact
    }

    private static func parseByteCount(_ value: String) -> Int64? {
        guard let groups = lastCaptureGroups(
            in: value,
            pattern: #"([0-9]+(?:\.[0-9]+)?)\s*([KMGT]?i?B)"#,
            captureCount: 2,
            caseInsensitive: true
        ), let number = Double(groups[0]) else { return nil }
        let unit = groups[1].uppercased().replacingOccurrences(of: "I", with: "")
        let multiplier: Double
        switch unit {
        case "KB": multiplier = 1_024
        case "MB": multiplier = 1_024 * 1_024
        case "GB": multiplier = 1_024 * 1_024 * 1_024
        case "TB": multiplier = 1_024 * 1_024 * 1_024 * 1_024
        default: multiplier = 1
        }
        return Int64(number * multiplier)
    }

    private static func lastCaptureGroups(
        in text: String,
        pattern: String,
        captureCount: Int,
        caseInsensitive: Bool
    ) -> [String]? {
        let options: NSRegularExpression.Options = caseInsensitive ? [.caseInsensitive] : []
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options),
              let match = regex.matches(
                in: text,
                range: NSRange(text.startIndex..<text.endIndex, in: text)
              ).last,
              match.numberOfRanges > captureCount else { return nil }
        return (1...captureCount).compactMap { index in
            guard let range = Range(match.range(at: index), in: text) else { return nil }
            return String(text[range])
        }
    }
}
