import Foundation
import SwiftData

@Model
final class ServerConfiguration {
    var serverURL: String
    var accessPassword: String?
    var lastConnectedAt: Date?

    init(serverURL: String, accessPassword: String? = nil, lastConnectedAt: Date? = nil) {
        self.serverURL = serverURL
        self.accessPassword = accessPassword
        self.lastConnectedAt = lastConnectedAt
    }
}

@Model
final class CatalogPageCache {
    var serverURL: String
    var page: Int
    var payload: Data
    var hasNext: Bool
    var pageSize: Int
    var updatedAt: Date

    init(serverURL: String, page: Int, payload: Data, hasNext: Bool, pageSize: Int, updatedAt: Date = Date()) {
        self.serverURL = serverURL
        self.page = page
        self.payload = payload
        self.hasNext = hasNext
        self.pageSize = pageSize
        self.updatedAt = updatedAt
    }
}

struct HealthStatus: Codable {
    let status: String
    let architecture: String
    let media: String
    let downloader: Bool
    let browser: Bool
}

struct LicenseInfo: Codable {
    let ok: Bool?
    let activated: Bool
    let deviceID: String?
    let expiresAt: Double?
    let message: String?

    enum CodingKeys: String, CodingKey {
        case ok, activated, message
        case deviceID = "device_id"
        case expiresAt = "expires_at"
    }
}

struct LicenseAdminSummary: Codable {
    let ok: Bool?
    let records: [LicenseAdminRecord]
    let revoked: [String]
    let updatedAt: Double?
    let onlineCount: Int
    let recordCount: Int
    let revokedCount: Int
    let baseURL: String?
    let revocationURL: String?
    let issued: String?
    let expiresText: String?

    enum CodingKeys: String, CodingKey {
        case ok, records, revoked, issued
        case updatedAt = "updated_at"
        case onlineCount = "online_count"
        case recordCount = "record_count"
        case revokedCount = "revoked_count"
        case baseURL = "base_url"
        case revocationURL = "revocation_url"
        case expiresText = "expires_text"
    }
}

struct LicenseAdminRecord: Codable, Identifiable {
    var id: String { deviceID }
    let deviceID: String
    let owner: String
    let code: String
    let days: Int
    let issuedAt: Double?
    let expiresAt: Double?
    let lastSeen: Double?
    let lastIP: String
    let hostname: String
    let appVersion: String
    let online: Bool
    let revoked: Bool

    enum CodingKeys: String, CodingKey {
        case owner, code, days, online, revoked, hostname
        case deviceID = "device_id"
        case issuedAt = "issued_at"
        case expiresAt = "expires_at"
        case lastSeen = "last_seen"
        case lastIP = "last_ip"
        case appVersion = "app_version"
    }
}

struct AccessInfo: Codable {
    let ok: Bool?
    let configured: Bool
    let authenticated: Bool
    let message: String?
}

struct HeroStats: Codable {
    let cloudActive: Int
    let cloudDone: Int
    let strmCount: Int
    let autoToday: Int

    enum CodingKeys: String, CodingKey {
        case cloudActive = "cloud_active"
        case cloudDone = "cloud_done"
        case strmCount = "strm_count"
        case autoToday = "auto_today"
    }
}

struct CatalogPageResponse: Codable {
    let page: Int
    let items: [CatalogItem]
    let pageSize: Int
    let hasNext: Bool

    enum CodingKeys: String, CodingKey {
        case page, items
        case pageSize = "page_size"
        case hasNext = "has_next"
    }
}

struct CatalogItem: Codable, Identifiable {
    var id: String { detailURL }
    var detailURL: String
    var title: String
    var catalog: String
    var imageURL: String
    var duration: String

    enum CodingKeys: String, CodingKey {
        case detailURL = "detail_url"
        case title
        case catalog
        case imageURL = "image_url"
        case duration
    }
}

struct MagnetItem: Codable, Identifiable {
    var id: String { url }
    var name: String
    var url: String
    var size: String
    var files: String
}

struct JableDetail: Codable {
    var detailURL: String
    var title: String
    var catalog: String
    var coverURL: String
    var samples: [String]
    var magnets: [MagnetItem]

    enum CodingKeys: String, CodingKey {
        case detailURL = "detail_url"
        case title
        case catalog
        case coverURL = "cover_url"
        case samples
        case magnets
    }
}

struct CapturedMedia: Codable {
    let detailURL: String
    let title: String
    let catalog: String
    let mediaURL: String

    enum CodingKeys: String, CodingKey {
        case detailURL = "detail_url"
        case title
        case catalog
        case mediaURL = "media_url"
    }
}

struct LocalVideoItem: Codable, Identifiable {
    var id: String
    var title: String
    var poster: String
}

struct LocalVideoDetail: Codable, Identifiable {
    var id: String
    var title: String
    var releaseDate: String
    var fanarts: [String]
    var videoFile: String?
}

struct MediaFile: Codable, Identifiable {
    var id: String { path }
    let path: String
    let name: String
    let size: Int64
}

struct LocalLibrarySeries: Identifiable {
    let id: String
    let title: String
    let catalog: String
    let source: String
    let coverPath: String
    let episodes: [MediaFile]

    var episodeCount: Int { episodes.count }
    var totalSize: Int64 { episodes.reduce(0) { $0 + $1.size } }
}

struct CloudTask: Codable, Identifiable {
    var id: String
    var title: String
    var catalog: String
    var state: String
    var message: String
    var playURL: String
    var filePath: String
    var createdAt: String
    var detailURL: String
    var strmID: String?
    var pickcode: String?
    var coverURL: String

    enum CodingKeys: String, CodingKey {
        case id, title, catalog, state, message, pickcode
        case playURL = "play_url"
        case filePath = "file_path"
        case createdAt = "created_at"
        case detailURL = "detail_url"
        case strmID = "strm_id"
        case coverURL = "cover_url"
    }
}

struct StrmItem: Codable, Identifiable {
    var id: String
    var catalog: String
    var title: String
    var filePath: String
    var size: Int64?
    var createdAt: String
    var posterPath: String
    var strmPath: String
    var pickcode: String?
    var coverURL: String

    enum CodingKeys: String, CodingKey {
        case id, catalog, title, size, pickcode
        case filePath = "file_path"
        case createdAt = "created_at"
        case posterPath = "poster_path"
        case strmPath = "strm_path"
        case coverURL = "cover_url"
    }
}

struct DownloadTask: Codable, Identifiable {
    var id: String
    var title: String
    var catalog: String
    var performer: String
    var state: String
    var phase: String
    var progress: Double
    var speed: String
    var size: String
    var eta: String
    var coverURL: String
    var outputPath: String
    var resultMessage: String
    var threads: Int
    var createdAt: String
    var taskType: String
    var strmID: String?
    var pickcode: String?
    var downloadStep: String
    var scrapeStep: String
    var organizeStep: String

    enum CodingKeys: String, CodingKey {
        case id, title, catalog, performer, state, phase, progress, speed, size, eta, threads
        case coverURL = "cover_url"
        case outputPath = "output_path"
        case resultMessage = "result_message"
        case createdAt = "created_at"
        case taskType = "task_type"
        case strmID = "strm_id"
        case pickcode
        case downloadStep = "download_step"
        case scrapeStep = "scrape_step"
        case organizeStep = "organize_step"
    }
}

struct AppSettings: Codable {
    var threads: Int?
    var proxy: String?
    var jableCookie: String?
    var privacyMode: Bool?
    var serviceBaseURL: String?
    var cloud115Mode: String?
    var cloud115Cookie: String?
    var cloud115Endpoint: String?
    var organizeEnabled: Bool?
    var allowDuplicate: Bool?
    var mediaRoot: String?
    var failureRouteEnabled: Bool?
    var failurePath: String?
    var localScrapeEnabled: Bool?
    var localTransferEnabled: Bool?
    var localTransferPath: String?
    var manualScrapeEnabled: Bool?
    var manualTransferEnabled: Bool?
    var manualTransferPath: String?
    var watchEnabled: Bool?
    var watchDir: String?
    var watchInterval: Int?
    var cloud115Token: String?
    var cloud115PlayMode: String?
    var cloud115SigninEnabled: Bool?
    var cloud115SigninCron: String?
    var cloud115SigninRetryCount: Int?
    var cloud115SigninRetryInterval: Int?
    var cloudTransferEnabled: Bool?
    var cloudTransferPath: String?
    var cloudTransferCid: String?
    var cloudPollInterval: Int?
    var cloudAdMinMB: Double?
    var autoStrmEnabled: Bool?
    var strmRootDir: String?
    var autoOfflineEnabled: Bool?
    var autoOfflineBrowse: Bool?
    var autoOfflineSchedule: Bool?
    var autoOfflineInterval: Int?
    var autoOfflinePages: Int?
    var autoOfflineWhitelist: String?
    var autoOfflineMinDuration: Int?
    var autoOfflineMinSize: Double?
    var autoOfflineDailyLimit: Int?
    var hgUploadStrategy: String?
    var hgDeleteAfterUpload: Bool?
    var hgTargetCid: String?
    var hgTargetPath: String?
    var hgCheckInterval: Int?
    var hgUseProxy: Bool?
    var hgSiteMirrors: String?
    var hgEpisodeConcurrency: Int?
    var hgFollowEnabled: Bool?
    var hgFollowPages: Int?

    enum CodingKeys: String, CodingKey {
        case threads, proxy
        case jableCookie = "jable_cookie"
        case privacyMode = "privacy_mode"
        case serviceBaseURL = "service_base_url"
        case cloud115Mode = "cloud115_mode"
        case cloud115Cookie = "cloud115_cookie"
        case cloud115Endpoint = "cloud115_endpoint"
        case organizeEnabled = "organize_enabled"
        case allowDuplicate = "allow_duplicate"
        case mediaRoot = "media_root"
        case failureRouteEnabled = "failure_route_enabled"
        case failurePath = "failure_path"
        case localScrapeEnabled = "local_scrape_enabled"
        case localTransferEnabled = "local_transfer_enabled"
        case localTransferPath = "local_transfer_path"
        case manualScrapeEnabled = "manual_scrape_enabled"
        case manualTransferEnabled = "manual_transfer_enabled"
        case manualTransferPath = "manual_transfer_path"
        case watchEnabled = "watch_enabled"
        case watchDir = "watch_dir"
        case watchInterval = "watch_interval"
        case cloud115Token = "cloud115_token"
        case cloud115PlayMode = "cloud115_play_mode"
        case cloud115SigninEnabled = "cloud115_signin_enabled"
        case cloud115SigninCron = "cloud115_signin_cron"
        case cloud115SigninRetryCount = "cloud115_signin_retry_count"
        case cloud115SigninRetryInterval = "cloud115_signin_retry_interval"
        case cloudTransferEnabled = "cloud_transfer_enabled"
        case cloudTransferPath = "cloud_transfer_path"
        case cloudTransferCid = "cloud_transfer_cid"
        case cloudPollInterval = "cloud_poll_interval"
        case cloudAdMinMB = "cloud_ad_min_mb"
        case autoStrmEnabled = "auto_strm_enabled"
        case strmRootDir = "strm_root_dir"
        case autoOfflineEnabled = "auto_offline_enabled"
        case autoOfflineBrowse = "auto_offline_browse"
        case autoOfflineSchedule = "auto_offline_schedule"
        case autoOfflineInterval = "auto_offline_interval"
        case autoOfflinePages = "auto_offline_pages"
        case autoOfflineWhitelist = "auto_offline_whitelist"
        case autoOfflineMinDuration = "auto_offline_min_duration"
        case autoOfflineMinSize = "auto_offline_min_size"
        case autoOfflineDailyLimit = "auto_offline_daily_limit"
        case hgUploadStrategy = "hg_upload_strategy"
        case hgDeleteAfterUpload = "hg_delete_after_upload"
        case hgTargetCid = "hg_target_cid"
        case hgTargetPath = "hg_target_path"
        case hgCheckInterval = "hg_check_interval"
        case hgUseProxy = "hg_use_proxy"
        case hgSiteMirrors = "hg_site_mirrors"
        case hgEpisodeConcurrency = "hg_episode_concurrency"
        case hgFollowEnabled = "hg_follow_enabled"
        case hgFollowPages = "hg_follow_pages"
    }
}

struct HuangguoCatalogResponse: Codable {
    let page: Int
    let items: [HuangguoCatalogItem]
    let tabs: [HuangguoTab]
    let sourceURL: String?

    enum CodingKeys: String, CodingKey {
        case page, items, tabs
        case sourceURL = "source_url"
    }
}

struct HuangguoTab: Codable, Identifiable, Hashable {
    var id: String
    var name: String
}

struct HuangguoCatalogItem: Codable, Identifiable {
    var id: String
    var title: String
    var detailURL: String
    var coverURL: String
    var remark: String
    var score: String

    enum CodingKeys: String, CodingKey {
        case id, title, remark, score
        case detailURL = "detail_url"
        case coverURL = "cover_url"
    }
}

struct HuangguoSeries: Codable, Identifiable {
    var id: String
    var title: String
    var detailURL: String
    var coverURL: String
    var totalEpisodes: Int
    var downloadedEpisodes: Int
    var uploadedEpisodes: Int
    var latestEpisode: Int
    var completed: Int
    var failedCount: Int
    var activeEpisodes: [HuangguoActiveEpisode]
    var rating: String
    var premiered: String

    enum CodingKeys: String, CodingKey {
        case id, title, rating, premiered, completed
        case detailURL = "detail_url"
        case coverURL = "cover_url"
        case totalEpisodes = "total_episodes"
        case downloadedEpisodes = "downloaded_episodes"
        case uploadedEpisodes = "uploaded_episodes"
        case latestEpisode = "latest_episode"
        case failedCount = "failed_count"
        case activeEpisodes = "active_episodes"
    }
}

struct HuangguoActiveEpisode: Codable, Identifiable {
    var id: Int { ep }
    var ep: Int
    var state: String
    var progress: Double
    var message: String
}

struct HuangguoEpisode: Codable, Identifiable {
    var id: String
    var seriesID: String
    var ep: Int
    var title: String
    var playURL: String
    var state: String
    var uploadState: String
    var progress: Double
    var message: String
    var error: String
    var filePath: String
    var uploadPath: String
    var pickcode: String

    enum CodingKeys: String, CodingKey {
        case id, ep, title, state, progress, message, error, pickcode
        case seriesID = "series_id"
        case playURL = "play_url"
        case uploadState = "upload_state"
        case filePath = "file_path"
        case uploadPath = "upload_path"
    }
}

struct HuangguoEpisodeTask: Codable, Identifiable {
    var id: String
    var seriesID: String
    var ep: Int
    var episodeTitle: String
    var seriesTitle: String
    var state: String
    var uploadState: String
    var progress: Double
    var message: String
    var error: String
    var filePath: String
    var uploadPath: String
    var coverURL: String
    var createdAt: String
    var updatedAt: String

    enum CodingKeys: String, CodingKey {
        case id, ep, state, progress, message, error
        case seriesID = "series_id"
        case episodeTitle = "episode_title"
        case seriesTitle = "series_title"
        case uploadState = "upload_state"
        case filePath = "file_path"
        case uploadPath = "upload_path"
        case coverURL = "cover_url"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

struct HuangguoOnlineSeries: Codable {
    var id: String
    var title: String
    var detailURL: String
    var coverURL: String
    var episodes: [HuangguoOnlineEpisode]

    enum CodingKeys: String, CodingKey {
        case id, title, episodes
        case detailURL = "detail_url"
        case coverURL = "cover_url"
    }
}

struct HuangguoOnlineEpisode: Codable, Identifiable {
    var id: Int { ep }
    var ep: Int
    var playURL: String
    var locked: Bool

    enum CodingKeys: String, CodingKey {
        case ep, locked
        case playURL = "play_url"
    }
}

struct HuangguoSeriesCreateResponse: Codable {
    let ok: Bool?
    let existed: Bool?
    let queued: Int?
    let series: HuangguoSeries
    let episodes: [HuangguoEpisode]
}

struct CountResponse: Codable {
    let ok: Bool?
    let queued: Int?
    let added: Int?
}

struct TaskCreationResponse: Codable {
    let id: String
}

struct LoginCheckResponse: Codable {
    let ok: Bool
    let message: String
}

struct Cloud115SigninStatus: Codable {
    let ok: Bool?
    let enabled: Bool
    let cron: String
    let retryCount: Int
    let retryInterval: Int
    let logs: [Cloud115SigninLog]
    let message: String?

    enum CodingKeys: String, CodingKey {
        case ok, enabled, cron, logs, message
        case retryCount = "retry_count"
        case retryInterval = "retry_interval"
    }
}

struct Cloud115SigninLog: Codable, Identifiable {
    let id: String
    let createdAt: String
    let state: String
    let message: String
    let reward: String

    enum CodingKeys: String, CodingKey {
        case id, state, message, reward
        case createdAt = "created_at"
    }
}

extension KeyedDecodingContainer {
    func decodeString(_ key: Key) -> String {
        (try? decode(String.self, forKey: key)) ?? ""
    }

    func decodeStringIfPresent(_ key: Key) -> String? {
        try? decodeIfPresent(String.self, forKey: key)
    }

    func decodeInt(_ key: Key) -> Int {
        if let value = try? decode(Int.self, forKey: key) { return value }
        if let value = try? decode(String.self, forKey: key), let intValue = Int(value) { return intValue }
        return 0
    }

    func decodeDouble(_ key: Key) -> Double {
        if let value = try? decode(Double.self, forKey: key) { return value }
        if let value = try? decode(Int.self, forKey: key) { return Double(value) }
        if let value = try? decode(String.self, forKey: key), let doubleValue = Double(value) { return doubleValue }
        return 0
    }

    func decodeBool(_ key: Key) -> Bool {
        if let value = try? decode(Bool.self, forKey: key) { return value }
        if let value = try? decode(Int.self, forKey: key) { return value != 0 }
        if let value = try? decode(String.self, forKey: key) {
            return ["1", "true", "yes", "on"].contains(value.lowercased())
        }
        return false
    }
}

extension CatalogItem {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        detailURL = c.decodeString(.detailURL)
        title = c.decodeString(.title)
        catalog = c.decodeString(.catalog)
        imageURL = c.decodeString(.imageURL)
        duration = c.decodeString(.duration)
    }
}

extension MagnetItem {
    enum CodingKeys: String, CodingKey { case name, url, size, files }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = c.decodeString(.name)
        url = c.decodeString(.url)
        size = c.decodeString(.size)
        files = c.decodeString(.files)
    }
}

extension JableDetail {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        detailURL = c.decodeString(.detailURL)
        title = c.decodeString(.title)
        catalog = c.decodeString(.catalog)
        coverURL = c.decodeString(.coverURL)
        samples = (try? c.decode([String].self, forKey: .samples)) ?? []
        magnets = (try? c.decode([MagnetItem].self, forKey: .magnets)) ?? []
    }
}

extension LicenseAdminSummary {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ok = try? c.decodeIfPresent(Bool.self, forKey: .ok)
        records = (try? c.decode([LicenseAdminRecord].self, forKey: .records)) ?? []
        revoked = (try? c.decode([String].self, forKey: .revoked)) ?? []
        updatedAt = try? c.decodeIfPresent(Double.self, forKey: .updatedAt)
        onlineCount = c.decodeInt(.onlineCount)
        recordCount = c.decodeInt(.recordCount)
        revokedCount = c.decodeInt(.revokedCount)
        baseURL = c.decodeStringIfPresent(.baseURL)
        revocationURL = c.decodeStringIfPresent(.revocationURL)
        issued = c.decodeStringIfPresent(.issued)
        expiresText = c.decodeStringIfPresent(.expiresText)
    }
}

extension LicenseAdminRecord {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        deviceID = c.decodeString(.deviceID)
        owner = c.decodeString(.owner)
        code = c.decodeString(.code)
        days = c.decodeInt(.days)
        issuedAt = try? c.decodeIfPresent(Double.self, forKey: .issuedAt)
        expiresAt = try? c.decodeIfPresent(Double.self, forKey: .expiresAt)
        lastSeen = try? c.decodeIfPresent(Double.self, forKey: .lastSeen)
        lastIP = c.decodeString(.lastIP)
        hostname = c.decodeString(.hostname)
        appVersion = c.decodeString(.appVersion)
        online = c.decodeBool(.online)
        revoked = c.decodeBool(.revoked)
    }
}

extension LocalVideoItem {
    enum CodingKeys: String, CodingKey { case id, title, poster }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.decodeString(.id)
        title = c.decodeString(.title)
        poster = c.decodeString(.poster)
    }
}

extension LocalVideoDetail {
    enum CodingKeys: String, CodingKey { case id, title, releaseDate, fanarts, videoFile }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.decodeString(.id)
        title = c.decodeString(.title)
        releaseDate = c.decodeString(.releaseDate)
        fanarts = (try? c.decode([String].self, forKey: .fanarts)) ?? []
        videoFile = c.decodeStringIfPresent(.videoFile)
    }
}

extension CloudTask {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.decodeString(.id)
        title = c.decodeString(.title)
        catalog = c.decodeString(.catalog)
        state = c.decodeString(.state)
        message = c.decodeString(.message)
        playURL = c.decodeString(.playURL)
        filePath = c.decodeString(.filePath)
        createdAt = c.decodeString(.createdAt)
        detailURL = c.decodeString(.detailURL)
        strmID = c.decodeStringIfPresent(.strmID)
        pickcode = c.decodeStringIfPresent(.pickcode)
        coverURL = c.decodeString(.coverURL)
    }
}

extension StrmItem {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.decodeString(.id)
        catalog = c.decodeString(.catalog)
        title = c.decodeString(.title)
        filePath = c.decodeString(.filePath)
        size = try? c.decodeIfPresent(Int64.self, forKey: .size)
        createdAt = c.decodeString(.createdAt)
        posterPath = c.decodeString(.posterPath)
        strmPath = c.decodeString(.strmPath)
        pickcode = c.decodeStringIfPresent(.pickcode)
        coverURL = c.decodeString(.coverURL)
    }
}

extension DownloadTask {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.decodeString(.id)
        title = c.decodeString(.title)
        catalog = c.decodeString(.catalog)
        performer = c.decodeString(.performer)
        state = c.decodeString(.state)
        phase = c.decodeString(.phase)
        progress = (try? c.decode(Double.self, forKey: .progress)) ?? 0
        speed = c.decodeString(.speed)
        size = c.decodeString(.size)
        eta = c.decodeString(.eta)
        coverURL = c.decodeString(.coverURL)
        outputPath = c.decodeString(.outputPath)
        resultMessage = c.decodeString(.resultMessage)
        threads = (try? c.decode(Int.self, forKey: .threads)) ?? 1
        createdAt = c.decodeString(.createdAt)
        taskType = c.decodeString(.taskType)
        strmID = c.decodeStringIfPresent(.strmID)
        pickcode = c.decodeStringIfPresent(.pickcode)
        downloadStep = c.decodeString(.downloadStep)
        scrapeStep = c.decodeString(.scrapeStep)
        organizeStep = c.decodeString(.organizeStep)
    }
}

extension HuangguoCatalogResponse {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        page = c.decodeInt(.page)
        items = (try? c.decode([HuangguoCatalogItem].self, forKey: .items)) ?? []
        tabs = (try? c.decode([HuangguoTab].self, forKey: .tabs)) ?? []
        sourceURL = c.decodeStringIfPresent(.sourceURL)
    }
}

extension HuangguoTab {
    enum CodingKeys: String, CodingKey { case id, name }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.decodeString(.id)
        name = c.decodeString(.name)
    }
}

extension HuangguoCatalogItem {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.decodeString(.id)
        title = c.decodeString(.title)
        detailURL = c.decodeString(.detailURL)
        coverURL = c.decodeString(.coverURL)
        remark = c.decodeString(.remark)
        score = c.decodeString(.score)
    }
}

extension HuangguoSeries {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.decodeString(.id)
        title = c.decodeString(.title)
        detailURL = c.decodeString(.detailURL)
        coverURL = c.decodeString(.coverURL)
        totalEpisodes = c.decodeInt(.totalEpisodes)
        downloadedEpisodes = c.decodeInt(.downloadedEpisodes)
        uploadedEpisodes = c.decodeInt(.uploadedEpisodes)
        latestEpisode = c.decodeInt(.latestEpisode)
        completed = c.decodeInt(.completed)
        failedCount = c.decodeInt(.failedCount)
        activeEpisodes = (try? c.decode([HuangguoActiveEpisode].self, forKey: .activeEpisodes)) ?? []
        rating = c.decodeString(.rating)
        premiered = c.decodeString(.premiered)
    }
}

extension HuangguoActiveEpisode {
    enum CodingKeys: String, CodingKey { case ep, state, progress, message }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ep = c.decodeInt(.ep)
        state = c.decodeString(.state)
        progress = c.decodeDouble(.progress)
        message = c.decodeString(.message)
    }
}

extension HuangguoEpisode {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.decodeString(.id)
        seriesID = c.decodeString(.seriesID)
        ep = c.decodeInt(.ep)
        title = c.decodeString(.title)
        playURL = c.decodeString(.playURL)
        state = c.decodeString(.state)
        uploadState = c.decodeString(.uploadState)
        progress = c.decodeDouble(.progress)
        message = c.decodeString(.message)
        error = c.decodeString(.error)
        filePath = c.decodeString(.filePath)
        uploadPath = c.decodeString(.uploadPath)
        pickcode = c.decodeString(.pickcode)
    }
}

extension HuangguoEpisodeTask {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.decodeString(.id)
        seriesID = c.decodeString(.seriesID)
        ep = c.decodeInt(.ep)
        episodeTitle = c.decodeString(.episodeTitle)
        seriesTitle = c.decodeString(.seriesTitle)
        state = c.decodeString(.state)
        uploadState = c.decodeString(.uploadState)
        progress = c.decodeDouble(.progress)
        message = c.decodeString(.message)
        error = c.decodeString(.error)
        filePath = c.decodeString(.filePath)
        uploadPath = c.decodeString(.uploadPath)
        coverURL = c.decodeString(.coverURL)
        createdAt = c.decodeString(.createdAt)
        updatedAt = c.decodeString(.updatedAt)
    }
}

extension HuangguoOnlineSeries {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.decodeString(.id)
        title = c.decodeString(.title)
        detailURL = c.decodeString(.detailURL)
        coverURL = c.decodeString(.coverURL)
        episodes = (try? c.decode([HuangguoOnlineEpisode].self, forKey: .episodes)) ?? []
    }
}

extension HuangguoOnlineEpisode {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ep = c.decodeInt(.ep)
        playURL = c.decodeString(.playURL)
        locked = c.decodeBool(.locked)
    }
}

enum APIError: LocalizedError {
    case invalidURL
    case badServerResponse(String)
    case invalidPayload
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "服务地址无效，请检查后重试。"
        case .badServerResponse(let message):
            return message
        case .invalidPayload:
            return "服务返回了无法识别的数据。"
        case .transport(let message):
            return message
        }
    }
}

struct APIClient {
    let baseURL: String
    let accessPassword: String

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 25
        configuration.waitsForConnectivity = false
        configuration.allowsCellularAccess = true
        configuration.allowsExpensiveNetworkAccess = true
        configuration.allowsConstrainedNetworkAccess = true
        configuration.httpShouldSetCookies = true
        configuration.httpCookieAcceptPolicy = .always
        configuration.httpAdditionalHeaders = [
            "Accept": "application/json, text/plain, */*",
            "Accept-Language": "zh-CN,zh;q=0.9,en;q=0.7",
            "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1 JableMediaLibrary/1.0.4"
        ]
        return URLSession(configuration: configuration)
    }()

    private var normalizedBaseURL: String {
        baseURL.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    init(baseURL: String, accessPassword: String = "") {
        self.baseURL = baseURL
        self.accessPassword = accessPassword.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func health() async throws -> HealthStatus {
        try await request(path: "/api/health", method: "GET")
    }

    func accessStatus() async throws -> AccessInfo {
        try await request(path: "/api/access/status", method: "GET")
    }

    func accessLogin(password: String) async throws -> AccessInfo {
        try await request(path: "/api/access/login", method: "POST", body: ["password": password])
    }

    func license() async throws -> LicenseInfo {
        try await request(path: "/api/license", method: "GET")
    }

    func activateLicense(code: String) async throws -> LicenseInfo {
        try await request(path: "/api/license/activate", method: "POST", body: ["license_code": code])
    }

    func catalog(page: Int, force: Bool) async throws -> CatalogPageResponse {
        var components = URLComponents()
        components.queryItems = [
            URLQueryItem(name: "page", value: "\(max(1, page))"),
            URLQueryItem(name: "refresh", value: force ? "1" : "0")
        ]
        return try await request(path: "/api/jable/catalog?\(components.percentEncodedQuery ?? "")", method: "GET")
    }

    func tasks() async throws -> [DownloadTask] {
        try await request(path: "/api/tasks", method: "GET")
    }

    func cloudTasks() async throws -> [CloudTask] {
        try await request(path: "/api/cloud-tasks", method: "GET")
    }

    func strmLibrary() async throws -> [StrmItem] {
        try await request(path: "/api/strm-library", method: "GET")
    }

    func mediaFiles() async throws -> [MediaFile] {
        try await request(path: "/api/media-files", method: "GET")
    }

    func heroStats() async throws -> HeroStats {
        try await request(path: "/api/hero-stats", method: "GET")
    }

    func settings() async throws -> AppSettings {
        try await request(path: "/api/settings", method: "GET")
    }

    func saveSettings(_ settings: AppSettings) async throws -> AppSettings {
        var object: [String: Any] = [:]
        if let threads = settings.threads { object["threads"] = threads }
        if let proxy = settings.proxy { object["proxy"] = proxy }
        if let jableCookie = settings.jableCookie { object["jable_cookie"] = jableCookie }
        if let privacyMode = settings.privacyMode { object["privacy_mode"] = privacyMode }
        if let serviceBaseURL = settings.serviceBaseURL { object["service_base_url"] = serviceBaseURL }
        if let cloud115Mode = settings.cloud115Mode { object["cloud115_mode"] = cloud115Mode }
        if let cloud115Cookie = settings.cloud115Cookie { object["cloud115_cookie"] = cloud115Cookie }
        if let cloud115Endpoint = settings.cloud115Endpoint { object["cloud115_endpoint"] = cloud115Endpoint }
        if let organizeEnabled = settings.organizeEnabled { object["organize_enabled"] = organizeEnabled }
        if let allowDuplicate = settings.allowDuplicate { object["allow_duplicate"] = allowDuplicate }
        if let failureRouteEnabled = settings.failureRouteEnabled { object["failure_route_enabled"] = failureRouteEnabled }
        if let failurePath = settings.failurePath { object["failure_path"] = failurePath }
        if let localScrapeEnabled = settings.localScrapeEnabled { object["local_scrape_enabled"] = localScrapeEnabled }
        if let localTransferEnabled = settings.localTransferEnabled { object["local_transfer_enabled"] = localTransferEnabled }
        if let localTransferPath = settings.localTransferPath { object["local_transfer_path"] = localTransferPath }
        if let manualScrapeEnabled = settings.manualScrapeEnabled { object["manual_scrape_enabled"] = manualScrapeEnabled }
        if let manualTransferEnabled = settings.manualTransferEnabled { object["manual_transfer_enabled"] = manualTransferEnabled }
        if let manualTransferPath = settings.manualTransferPath { object["manual_transfer_path"] = manualTransferPath }
        if let watchEnabled = settings.watchEnabled { object["watch_enabled"] = watchEnabled }
        if let watchDir = settings.watchDir { object["watch_dir"] = watchDir }
        if let watchInterval = settings.watchInterval { object["watch_interval"] = watchInterval }
        if let cloud115Token = settings.cloud115Token { object["cloud115_token"] = cloud115Token }
        if let cloud115PlayMode = settings.cloud115PlayMode { object["cloud115_play_mode"] = cloud115PlayMode }
        if let cloud115SigninEnabled = settings.cloud115SigninEnabled { object["cloud115_signin_enabled"] = cloud115SigninEnabled }
        if let cloud115SigninCron = settings.cloud115SigninCron { object["cloud115_signin_cron"] = cloud115SigninCron }
        if let cloud115SigninRetryCount = settings.cloud115SigninRetryCount { object["cloud115_signin_retry_count"] = cloud115SigninRetryCount }
        if let cloud115SigninRetryInterval = settings.cloud115SigninRetryInterval { object["cloud115_signin_retry_interval"] = cloud115SigninRetryInterval }
        if let cloudTransferEnabled = settings.cloudTransferEnabled { object["cloud_transfer_enabled"] = cloudTransferEnabled }
        if let cloudTransferPath = settings.cloudTransferPath { object["cloud_transfer_path"] = cloudTransferPath }
        if let cloudTransferCid = settings.cloudTransferCid { object["cloud_transfer_cid"] = cloudTransferCid }
        if let cloudPollInterval = settings.cloudPollInterval { object["cloud_poll_interval"] = cloudPollInterval }
        if let cloudAdMinMB = settings.cloudAdMinMB { object["cloud_ad_min_mb"] = cloudAdMinMB }
        if let autoStrmEnabled = settings.autoStrmEnabled { object["auto_strm_enabled"] = autoStrmEnabled }
        if let serviceBaseURL = settings.serviceBaseURL { object["service_base_url"] = serviceBaseURL }
        if let strmRootDir = settings.strmRootDir { object["strm_root_dir"] = strmRootDir }
        if let autoOfflineEnabled = settings.autoOfflineEnabled { object["auto_offline_enabled"] = autoOfflineEnabled }
        if let autoOfflineBrowse = settings.autoOfflineBrowse { object["auto_offline_browse"] = autoOfflineBrowse }
        if let autoOfflineSchedule = settings.autoOfflineSchedule { object["auto_offline_schedule"] = autoOfflineSchedule }
        if let autoOfflineInterval = settings.autoOfflineInterval { object["auto_offline_interval"] = autoOfflineInterval }
        if let autoOfflinePages = settings.autoOfflinePages { object["auto_offline_pages"] = autoOfflinePages }
        if let autoOfflineWhitelist = settings.autoOfflineWhitelist { object["auto_offline_whitelist"] = autoOfflineWhitelist }
        if let autoOfflineMinDuration = settings.autoOfflineMinDuration { object["auto_offline_min_duration"] = autoOfflineMinDuration }
        if let autoOfflineMinSize = settings.autoOfflineMinSize { object["auto_offline_min_size"] = autoOfflineMinSize }
        if let autoOfflineDailyLimit = settings.autoOfflineDailyLimit { object["auto_offline_daily_limit"] = autoOfflineDailyLimit }
        if let hgUploadStrategy = settings.hgUploadStrategy { object["hg_upload_strategy"] = hgUploadStrategy }
        if let hgDeleteAfterUpload = settings.hgDeleteAfterUpload { object["hg_delete_after_upload"] = hgDeleteAfterUpload }
        if let hgTargetCid = settings.hgTargetCid { object["hg_target_cid"] = hgTargetCid }
        if let hgTargetPath = settings.hgTargetPath { object["hg_target_path"] = hgTargetPath }
        if let hgCheckInterval = settings.hgCheckInterval { object["hg_check_interval"] = hgCheckInterval }
        if let hgUseProxy = settings.hgUseProxy { object["hg_use_proxy"] = hgUseProxy }
        if let hgSiteMirrors = settings.hgSiteMirrors { object["hg_site_mirrors"] = hgSiteMirrors }
        if let hgEpisodeConcurrency = settings.hgEpisodeConcurrency { object["hg_episode_concurrency"] = hgEpisodeConcurrency }
        if let hgFollowEnabled = settings.hgFollowEnabled { object["hg_follow_enabled"] = hgFollowEnabled }
        if let hgFollowPages = settings.hgFollowPages { object["hg_follow_pages"] = hgFollowPages }
        return try await request(path: "/api/settings", method: "PUT", body: object)
    }

    func huangguoCatalog(tab: String, page: Int, keyword: String, force: Bool) async throws -> HuangguoCatalogResponse {
        var components = URLComponents()
        components.queryItems = [
            URLQueryItem(name: "tab", value: tab),
            URLQueryItem(name: "page", value: "\(max(1, page))"),
            URLQueryItem(name: "q", value: keyword),
            URLQueryItem(name: "refresh", value: force ? "1" : "0")
        ]
        return try await request(path: "/api/hg/catalog?\(components.percentEncodedQuery ?? "")", method: "GET")
    }

    func huangguoSeries() async throws -> [HuangguoSeries] {
        try await request(path: "/api/hg/series", method: "GET")
    }

    func huangguoEpisodes(seriesID: String) async throws -> [HuangguoEpisode] {
        try await request(path: "/api/hg/series/\(seriesID)/episodes", method: "GET")
    }

    func huangguoRecentEpisodes(limit: Int = 150) async throws -> [HuangguoEpisodeTask] {
        try await request(path: "/api/hg/recent-episodes?limit=\(limit)", method: "GET")
    }

    func huangguoOnlineEpisodes(detailURL: String) async throws -> HuangguoOnlineSeries {
        var components = URLComponents()
        components.queryItems = [URLQueryItem(name: "url", value: detailURL)]
        return try await request(path: "/api/hg/online-episodes?\(components.percentEncodedQuery ?? "")", method: "GET")
    }

    func huangguoCreateSeries(url: String) async throws -> HuangguoSeriesCreateResponse {
        try await request(path: "/api/hg/series", method: "POST", body: ["url": url])
    }

    func huangguoCheck(seriesID: String) async throws -> CountResponse {
        try await request(path: "/api/hg/series/\(seriesID)/check", method: "POST", body: [:])
    }

    func huangguoRescrape(seriesID: String) async throws -> CountResponse {
        try await request(path: "/api/hg/series/\(seriesID)/rescrape", method: "POST", body: [:])
    }

    func huangguoDownloadMissing(seriesID: String) async throws -> CountResponse {
        try await request(path: "/api/hg/series/\(seriesID)/download-missing", method: "POST", body: [:])
    }

    func huangguoDownloadEpisode(episodeID: String) async throws -> OKResponse {
        try await request(path: "/api/hg/episodes/\(episodeID)/download", method: "POST", body: [:])
    }

    func huangguoRetryUpload(episodeID: String) async throws -> OKResponse {
        try await request(path: "/api/hg/episodes/\(episodeID)/retry-upload", method: "POST", body: [:])
    }

    func huangguoRetryFailedAll() async throws -> CountResponse {
        try await request(path: "/api/hg/retry-failed-all", method: "POST", body: [:])
    }

    func huangguoDownloadMissingAll() async throws -> CountResponse {
        try await request(path: "/api/hg/download-missing-all", method: "POST", body: [:])
    }

    func huangguoSetCompleted(seriesID: String, completed: Bool) async throws -> CountResponse {
        try await request(path: "/api/hg/series/\(seriesID)/complete", method: "POST", body: ["completed": completed])
    }

    func huangguoDeleteSeries(seriesID: String, deleteFiles: Bool) async throws -> OKResponse {
        try await request(path: "/api/hg/series/\(seriesID)?delete_files=\(deleteFiles ? "1" : "0")", method: "DELETE")
    }

    func huangguoScanAll() async throws -> OKResponse {
        try await request(path: "/api/hg/scan-all", method: "POST", body: [:])
    }

    func huangguoStopScanAll() async throws -> OKResponse {
        try await request(path: "/api/hg/scan-all/stop", method: "POST", body: [:])
    }

    func jableDetail(detailURL: String, duration: String) async throws -> JableDetail {
        var components = URLComponents()
        components.queryItems = [
            URLQueryItem(name: "detail_url", value: detailURL),
            URLQueryItem(name: "duration", value: duration)
        ]
        return try await request(path: "/api/jable/detail?\(components.percentEncodedQuery ?? "")", method: "GET")
    }

    func capture(detailURL: String) async throws -> CapturedMedia {
        try await request(path: "/api/jable/capture", method: "POST", body: ["detail_url": detailURL])
    }

    func autoTask(detailURL: String, threads: Int, organizeEnabled: Bool, allowDuplicate: Bool) async throws -> TaskCreationResponse {
        try await request(
            path: "/api/jable/auto-task",
            method: "POST",
            body: [
                "detail_url": detailURL,
                "threads": threads,
                "organize_enabled": organizeEnabled,
                "allow_duplicate": allowDuplicate
            ]
        )
    }

    func autoCloudTask(item: CatalogItem) async throws -> CapturedMedia {
        try await request(
            path: "/api/jable/auto-cloud-task",
            method: "POST",
            body: [
                "detail_url": item.detailURL,
                "title": item.title,
                "catalog": item.catalog
            ]
        )
    }

    func createCloudTask(sourceURL: String, title: String, catalog: String, detailURL: String) async throws -> CloudTask {
        try await request(
            path: "/api/cloud-tasks",
            method: "POST",
            body: [
                "source_url": sourceURL,
                "title": title,
                "catalog": catalog,
                "detail_url": detailURL
            ]
        )
    }

    func manualScrape(path: String, title: String, catalog: String, performer: String) async throws -> [String] {
        let response: ManualScrapeResponse = try await request(
            path: "/api/manual-scrape",
            method: "POST",
            body: [
                "path": path,
                "title": title,
                "catalog": catalog,
                "performer": performer
            ]
        )
        return response.ids
    }

    func retry(taskID: String) async throws -> OKResponse {
        try await request(path: "/api/tasks/\(taskID)/retry", method: "POST", body: [:])
    }

    func deleteCloudTask(id: String) async throws -> OKResponse {
        try await request(path: "/api/cloud-tasks/\(id)", method: "DELETE")
    }

    func deleteStrmItem(id: String) async throws -> OKResponse {
        try await request(path: "/api/strm-library/\(id)", method: "DELETE")
    }

    func pollCloudTasksNow() async throws -> OKResponse {
        try await request(path: "/api/cloud-tasks/poll-now", method: "POST", body: [:])
    }

    func check115Login() async throws -> LoginCheckResponse {
        try await request(path: "/api/115/check-login", method: "POST", body: [:])
    }

    func cloud115SigninStatus() async throws -> Cloud115SigninStatus {
        try await request(path: "/api/115/signin", method: "GET")
    }

    func runCloud115Signin() async throws -> Cloud115SigninStatus {
        try await request(path: "/api/115/signin", method: "POST", body: [:])
    }

    func createTask(url: String, title: String, catalog: String, performer: String, threads: Int, organizeEnabled: Bool, allowDuplicate: Bool) async throws -> TaskCreationResponse {
        try await request(
            path: "/api/tasks",
            method: "POST",
            body: [
                "url": url,
                "title": title,
                "catalog": catalog,
                "performer": performer,
                "threads": threads,
                "organize_enabled": organizeEnabled,
                "allow_duplicate": allowDuplicate
            ]
        )
    }

    func absoluteURL(_ path: String) -> URL? {
        if path.hasPrefix("http://") || path.hasPrefix("https://") {
            return URL(string: path)
        }
        return URL(string: normalizedBaseURL + path)
    }

    func proxiedImageURL(_ path: String) -> URL? {
        if path.isEmpty { return nil }
        if path.hasPrefix("http://") || path.hasPrefix("https://") {
            var components = URLComponents(string: normalizedBaseURL + "/api/proxy-image")
            components?.queryItems = [URLQueryItem(name: "url", value: path)]
            return components?.url
        }
        return absoluteURL(path)
    }

    func streamURL(for item: StrmItem) -> URL? {
        absoluteURL("/api/115/stream/\(item.id)")
    }

    func pickcodeURL(_ pickcode: String) -> URL? {
        absoluteURL("/api/115/play/\(pickcode)")
    }

    func localTaskPlayURL(_ taskID: String) -> URL? {
        absoluteURL("/api/tasks/\(taskID)/play")
    }

    func localMediaPlayURL(path: String) -> URL? {
        var components = URLComponents(string: normalizedBaseURL + "/api/media/play")
        components?.queryItems = [URLQueryItem(name: "path", value: path)]
        return components?.url
    }

    func huangguoCoverURL(seriesID: String) -> URL? {
        absoluteURL("/api/hg/cover/\(seriesID)")
    }

    func huangguoLocalCoverURL(seriesName: String) -> URL? {
        var components = URLComponents(string: normalizedBaseURL + "/api/hg/local-cover")
        components?.queryItems = [URLQueryItem(name: "name", value: seriesName)]
        return components?.url
    }

    func huangguoOnlinePlayURL(playURL: String, ep: Int) -> URL? {
        var components = URLComponents(string: normalizedBaseURL + "/api/hg/online-play")
        components?.queryItems = [
            URLQueryItem(name: "url", value: playURL),
            URLQueryItem(name: "ep", value: "\(ep)")
        ]
        return components?.url
    }

    private func makeURL(path: String) throws -> URL {
        guard !normalizedBaseURL.isEmpty, let url = URL(string: normalizedBaseURL + path) else {
            throw APIError.invalidURL
        }
        return url
    }

    private func request<T: Decodable>(path: String, method: String, body: [String: Any]? = nil) async throws -> T {
        var request = URLRequest(url: try makeURL(path: path))
        request.httpMethod = method
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if !accessPassword.isEmpty {
            request.setValue(accessPassword, forHTTPHeaderField: "X-Access-Password")
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await Self.session.data(for: request)
        } catch let error as URLError {
            throw APIError.transport(Self.transportMessage(for: error, baseURL: normalizedBaseURL))
        } catch {
            throw APIError.transport("连接失败：\(error.localizedDescription)")
        }
        guard let http = response as? HTTPURLResponse else {
            throw APIError.invalidPayload
        }
        if (200 ..< 300).contains(http.statusCode) {
            do {
                return try JSONDecoder().decode(T.self, from: data)
            } catch {
                throw APIError.invalidPayload
            }
        }
        if http.statusCode == 503 {
            throw APIError.badServerResponse("服务网关暂时不可用（HTTP 503）。网页首页可能可打开，但 API 尚未转发成功。")
        }
        if let message = try? JSONDecoder().decode([String: String].self, from: data) {
            throw APIError.badServerResponse(message["message"] ?? message["error"] ?? "服务返回错误：HTTP \(http.statusCode)")
        }
        throw APIError.badServerResponse("服务返回错误：HTTP \(http.statusCode)")
    }

    private static func transportMessage(for error: URLError, baseURL: String) -> String {
        switch error.code {
        case .timedOut:
            return "连接超时。请在 Safari 打开 \(baseURL)/api/health；若首页能打开但该地址不能打开，说明服务器没有对外转发 API。"
        case .cannotFindHost, .dnsLookupFailed:
            return "无法解析服务器域名，请检查地址或 DNS 设置。"
        case .cannotConnectToHost:
            return "无法连接服务器端口，请确认服务和端口转发已开启。"
        case .notConnectedToInternet:
            return "当前设备没有可用网络。内网 IP 需要连接对应的 Wi-Fi。"
        case .networkConnectionLost:
            return "网络连接中断，请稍后重试。"
        case .appTransportSecurityRequiresSecureConnection:
            return "iOS 阻止了非安全连接，请安装包含 HTTP 权限的新版本。"
        default:
            return "网络请求失败：\(error.localizedDescription)（\(error.code.rawValue)）"
        }
    }
}

extension Cloud115SigninStatus {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ok = try? c.decodeIfPresent(Bool.self, forKey: .ok)
        enabled = c.decodeBool(.enabled)
        cron = c.decodeString(.cron)
        retryCount = c.contains(.retryCount) ? c.decodeInt(.retryCount) : 2
        retryInterval = c.contains(.retryInterval) ? c.decodeInt(.retryInterval) : 60
        logs = (try? c.decode([Cloud115SigninLog].self, forKey: .logs)) ?? []
        message = c.decodeStringIfPresent(.message)
    }
}

extension Cloud115SigninLog {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.decodeString(.id)
        createdAt = c.decodeString(.createdAt)
        state = c.decodeString(.state)
        message = c.decodeString(.message)
        reward = c.decodeString(.reward)
    }
}

struct LicenseConsoleClient {
    let baseURL: String
    let password: String

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 25
        configuration.waitsForConnectivity = false
        configuration.allowsCellularAccess = true
        configuration.allowsExpensiveNetworkAccess = true
        configuration.allowsConstrainedNetworkAccess = true
        configuration.httpAdditionalHeaders = [
            "Accept": "application/json, text/plain, */*",
            "Accept-Language": "zh-CN,zh;q=0.9,en;q=0.7",
            "User-Agent": "JableMediaLibrary/1.0.5 iOS"
        ]
        return URLSession(configuration: configuration)
    }()

    private var normalizedBaseURL: String {
        var value = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !value.isEmpty, !value.hasPrefix("http://"), !value.hasPrefix("https://") {
            value = "http://" + value
        }
        return value.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    func health() async throws -> OKResponse {
        try await request(path: "/api/admin/health", method: "GET")
    }

    func summary() async throws -> LicenseAdminSummary {
        try await request(path: "/api/admin/summary", method: "GET")
    }

    func issue(deviceID: String, owner: String, days: Int) async throws -> LicenseAdminSummary {
        try await request(
            path: "/api/admin/issue",
            method: "POST",
            body: ["device_id": deviceID, "owner": owner, "days": max(0, days)]
        )
    }

    func revoke(deviceID: String) async throws -> LicenseAdminSummary {
        try await request(path: "/api/admin/revoke", method: "POST", body: ["device_id": deviceID])
    }

    func unrevoke(deviceID: String) async throws -> LicenseAdminSummary {
        try await request(path: "/api/admin/unrevoke", method: "POST", body: ["device_id": deviceID])
    }

    func deleteRecord(deviceID: String) async throws -> LicenseAdminSummary {
        try await request(path: "/api/admin/delete-record", method: "POST", body: ["device_id": deviceID])
    }

    private func makeURL(path: String) throws -> URL {
        guard !normalizedBaseURL.isEmpty, let url = URL(string: normalizedBaseURL + path) else {
            throw APIError.invalidURL
        }
        return url
    }

    private func request<T: Decodable>(path: String, method: String, body: [String: Any]? = nil) async throws -> T {
        var request = URLRequest(url: try makeURL(path: path))
        request.httpMethod = method
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue(password.trimmingCharacters(in: .whitespacesAndNewlines), forHTTPHeaderField: "X-License-Password")
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await Self.session.data(for: request)
        } catch let error as URLError {
            throw APIError.transport(Self.transportMessage(for: error, baseURL: normalizedBaseURL))
        } catch {
            throw APIError.transport("连接失败：\(error.localizedDescription)")
        }
        guard let http = response as? HTTPURLResponse else {
            throw APIError.invalidPayload
        }
        if (200 ..< 300).contains(http.statusCode) {
            do {
                return try JSONDecoder().decode(T.self, from: data)
            } catch {
                throw APIError.invalidPayload
            }
        }
        if let message = try? JSONDecoder().decode([String: String].self, from: data) {
            throw APIError.badServerResponse(message["message"] ?? message["error"] ?? "授权控制台返回错误：HTTP \(http.statusCode)")
        }
        throw APIError.badServerResponse("授权控制台返回错误：HTTP \(http.statusCode)")
    }

    private static func transportMessage(for error: URLError, baseURL: String) -> String {
        switch error.code {
        case .timedOut:
            return "授权控制台连接超时。请确认手机能访问 \(baseURL)/healthz，并检查端口 8789 是否对外开放。"
        case .cannotFindHost, .dnsLookupFailed:
            return "无法解析授权控制台域名，请检查地址或 DNS。"
        case .cannotConnectToHost:
            return "无法连接授权控制台端口，请确认 8789 服务正在运行。"
        case .notConnectedToInternet:
            return "当前设备没有可用网络。"
        case .appTransportSecurityRequiresSecureConnection:
            return "iOS 阻止了 HTTP 连接，请安装包含 HTTP 权限的新版本。"
        default:
            return "授权控制台请求失败：\(error.localizedDescription)（\(error.code.rawValue)）"
        }
    }
}

struct ManualScrapeResponse: Codable {
    let ids: [String]
}

struct OKResponse: Codable {
    let ok: Bool?
}
