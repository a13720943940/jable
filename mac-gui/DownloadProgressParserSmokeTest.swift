import Foundation

@main
struct DownloadProgressParserSmokeTest {
    static func main() {
        let log = """
        Vid Kbps 66.47% 1.47GB/2.22GB4.05MBps00:03:38
        Vid Kbps 70.28% 1.55GB/2.21GB3.95MBps00:03:04
        """
        let metrics = DownloadProgressParser.parse(log)
        precondition(metrics.progressPercentage == 70.28)
        precondition(metrics.speedText == "3.95MB/s")
        precondition(metrics.downloadedBytes == Int64(1.55 * 1_024 * 1_024 * 1_024))
        precondition(metrics.totalBytes == Int64(2.21 * 1_024 * 1_024 * 1_024))

        let slashFormat = DownloadProgressParser.parse("48.2% 740 MiB / 1.50 GiB 8.4 MiB/s")
        precondition(slashFormat.progressPercentage == 48.2)
        precondition(slashFormat.speedText == "8.4MiB/s")
        precondition(slashFormat.downloadedBytes == 740 * 1_024 * 1_024)
        print("Download progress parser smoke test passed")
    }
}
