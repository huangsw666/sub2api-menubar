import AppKit
import Foundation
import Security
import WebKit

private struct SiteConfig {
    let name: String
    let base_url: String
    let login_path: String
}

private struct UpstreamConfig: Decodable {
    let name: String
    let account_names: [String]
    let base_url: String
    let login_path: String?
    let key_name: String?
    let channel_group: String?

    var site: SiteConfig {
        SiteConfig(name: name, base_url: base_url, login_path: login_path ?? "/login")
    }

    func matches(accountName: String) -> Bool {
        account_names.contains { $0.caseInsensitiveCompare(accountName) == .orderedSame }
    }
}

private struct AIConfig: Decodable {
    let sub2api_base_url: String
    let sub2api_login_path: String?
    let tracked_user_id: Int?
    let tracked_api_key_id: Int?
    let tracked_group: String?
    let upstreams: [UpstreamConfig]?
    let usage_interval_seconds: Double?
    let channel_interval_seconds: Double?
    let balance_interval_seconds: Double?
    let http_timeout_seconds: Double?

    var sub2api: SiteConfig {
        SiteConfig(name: "Sub2API", base_url: sub2api_base_url, login_path: sub2api_login_path ?? "/login")
    }

    var usageInterval: Double { max(3, usage_interval_seconds ?? 10) }
    var channelInterval: Double { max(10, channel_interval_seconds ?? 30) }
    var balanceInterval: Double { max(10, balance_interval_seconds ?? 60) }
    var httpTimeout: Double { max(2, http_timeout_seconds ?? 8) }
    var upstreamOverrides: [UpstreamConfig] { upstreams ?? [] }
}

private struct TokenRecord: Codable {
    let accessToken: String
    let refreshToken: String?
    let expiresAt: Double?
}

private enum MonitorError: LocalizedError {
    case loginRequired(String)
    case invalidResponse(String)
    case http(Int)

    var errorDescription: String? {
        switch self {
        case .loginRequired(let site): return "\(site) 需要登录"
        case .invalidResponse(let message): return message
        case .http(let status): return "HTTP \(status)"
        }
    }
}

private final class KeychainTokenStore {
    private let service = "io.github.huangsw666.sub2api-menubar"
    private let legacyService = "local.ai-latency-monitor"

    func load(site: String) -> TokenRecord? {
        if let token = load(site: site, service: service) {
            return token
        }
        guard let token = load(site: site, service: legacyService) else {
            return nil
        }
        try? save(token, site: site)
        return token
    }

    private func load(site: String, service: String) -> TokenRecord? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: site,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(TokenRecord.self, from: data)
    }

    func save(_ token: TokenRecord, site: String) throws {
        let data = try JSONEncoder().encode(token)
        let identity: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: site,
        ]
        let changes: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(identity as CFDictionary, changes as CFDictionary)
        if status == errSecItemNotFound {
            var newItem = identity
            newItem[kSecValueData as String] = data
            newItem[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(newItem as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw NSError(domain: NSOSStatusErrorDomain, code: Int(addStatus))
            }
        } else if status != errSecSuccess {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }
}

private final class AuthenticatedAPIClient {
    private let site: SiteConfig
    private let timeout: Double
    private let tokens: KeychainTokenStore
    private let session: URLSession

    init(site: SiteConfig, timeout: Double, tokens: KeychainTokenStore) {
        self.site = site
        self.timeout = timeout
        self.tokens = tokens
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout + 2
        session = URLSession(configuration: configuration)
    }

    func get(path: String, query: [URLQueryItem] = [], completion: @escaping (Result<Any, Error>) -> Void) {
        request(method: "GET", path: path, query: query, body: nil, completion: completion)
    }

    func post(path: String, body: [String: Any], completion: @escaping (Result<Any, Error>) -> Void) {
        request(method: "POST", path: path, query: [], body: body, completion: completion)
    }

    private func request(
        method: String,
        path: String,
        query: [URLQueryItem],
        body: [String: Any]?,
        completion: @escaping (Result<Any, Error>) -> Void
    ) {
        guard let token = tokens.load(site: site.name) else {
            completion(.failure(MonitorError.loginRequired(site.name)))
            return
        }
        perform(method: method, path: path, query: query, body: body, token: token, retryAfterRefresh: true, completion: completion)
    }

    private func perform(
        method: String,
        path: String,
        query: [URLQueryItem],
        body: [String: Any]?,
        token: TokenRecord,
        retryAfterRefresh: Bool,
        completion: @escaping (Result<Any, Error>) -> Void
    ) {
        guard var components = URLComponents(string: site.base_url + path) else {
            completion(.failure(MonitorError.invalidResponse("无效接口地址")))
            return
        }
        components.queryItems = query.isEmpty ? nil : query
        guard let url = components.url else {
            completion(.failure(MonitorError.invalidResponse("无效接口地址")))
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeout
        request.setValue("Bearer \(token.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        session.dataTask(with: request) { [weak self] data, response, error in
            if let error { completion(.failure(error)); return }
            guard let http = response as? HTTPURLResponse else {
                completion(.failure(MonitorError.invalidResponse("接口没有 HTTP 响应")))
                return
            }
            if http.statusCode == 401, retryAfterRefresh, let refreshToken = token.refreshToken {
                self?.refresh(refreshToken: refreshToken) { result in
                    switch result {
                    case .success(let refreshed):
                        self?.perform(method: method, path: path, query: query, body: body, token: refreshed, retryAfterRefresh: false, completion: completion)
                    case .failure(let error): completion(.failure(error))
                    }
                }
                return
            }
            guard (200..<300).contains(http.statusCode), let data else {
                completion(.failure(http.statusCode == 401 ? MonitorError.loginRequired(self?.site.name ?? "站点") : MonitorError.http(http.statusCode)))
                return
            }
            do {
                let object = try JSONSerialization.jsonObject(with: data)
                completion(.success(Self.unwrap(object)))
            } catch {
                completion(.failure(error))
            }
        }.resume()
    }

    private func refresh(refreshToken: String, completion: @escaping (Result<TokenRecord, Error>) -> Void) {
        guard let url = URL(string: site.base_url + "/api/v1/auth/refresh") else {
            completion(.failure(MonitorError.invalidResponse("无效刷新地址")))
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["refresh_token": refreshToken])
        session.dataTask(with: request) { [weak self] data, response, error in
            if let error { completion(.failure(error)); return }
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), let data else {
                completion(.failure(MonitorError.loginRequired(self?.site.name ?? "站点")))
                return
            }
            do {
                let root = Self.unwrap(try JSONSerialization.jsonObject(with: data))
                guard let dictionary = root as? [String: Any],
                      let access = dictionary["access_token"] as? String, !access.isEmpty else {
                    throw MonitorError.invalidResponse("刷新响应缺少 access_token")
                }
                let expiresIn = Self.double(dictionary["expires_in"])
                let token = TokenRecord(
                    accessToken: access,
                    refreshToken: dictionary["refresh_token"] as? String ?? refreshToken,
                    expiresAt: expiresIn.map { Date().timeIntervalSince1970 + $0 }
                )
                try self?.tokens.save(token, site: self?.site.name ?? "")
                completion(.success(token))
            } catch {
                completion(.failure(error))
            }
        }.resume()
    }

    static func unwrap(_ object: Any) -> Any {
        guard let dictionary = object as? [String: Any] else { return object }
        if dictionary["data"] != nil, dictionary["code"] != nil {
            return dictionary["data"] as Any
        }
        return object
    }

    static func double(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return Double(string) }
        return nil
    }
}

private final class LoginWindowController: NSObject, WKNavigationDelegate, NSWindowDelegate {
    private let site: SiteConfig
    private let tokenStore: KeychainTokenStore
    private let webView: WKWebView
    private let window: NSWindow
    private var timer: Timer?
    var onLogin: (() -> Void)?
    var onClose: (() -> Void)?

    init(site: SiteConfig, tokenStore: KeychainTokenStore) {
        self.site = site
        self.tokenStore = tokenStore
        webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 920, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        super.init()
        window.title = "登录 \(site.name)"
        window.center()
        window.contentView = webView
        window.delegate = self
        webView.navigationDelegate = self
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        if let url = URL(string: site.base_url + site.login_path) {
            webView.load(URLRequest(url: url))
        }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.captureToken()
        }
    }

    private func captureToken() {
        let script = """
        JSON.stringify({
          accessToken: localStorage.getItem('auth_token'),
          refreshToken: localStorage.getItem('refresh_token'),
          expiresAt: localStorage.getItem('token_expires_at')
        })
        """
        webView.evaluateJavaScript(script) { [weak self] result, _ in
            guard let self, let json = result as? String,
                  let data = json.data(using: .utf8),
                  let values = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let access = values["accessToken"] as? String, !access.isEmpty else { return }
            let expiresAt: Double?
            if let value = values["expiresAt"] as? String { expiresAt = Double(value).map { $0 / 1000 } }
            else { expiresAt = nil }
            let token = TokenRecord(
                accessToken: access,
                refreshToken: values["refreshToken"] as? String,
                expiresAt: expiresAt
            )
            guard (try? self.tokenStore.save(token, site: self.site.name)) != nil else { return }
            self.timer?.invalidate()
            self.timer = nil
            self.window.orderOut(nil)
            self.onLogin?()
            self.onClose?()
        }
    }

    func windowWillClose(_ notification: Notification) {
        timer?.invalidate()
        timer = nil
        onClose?()
    }
}

private struct UsageSnapshot {
    let accountID: Int
    let account: String
    let model: String
    let group: String
    let firstTokenMs: Double
    let durationMs: Double?
    let createdAt: String
}

private struct AccountSnapshot {
    let id: Int
    let name: String
    let type: String
    let status: String
    let schedulable: Bool
    let concurrency: Int
    let currentConcurrency: Int
    let rateMultiplier: Double
    let lastUsedAt: String?
    let remaining5h: Double?
    let remaining7d: Double?

    var isSubscription: Bool { type.lowercased() == "oauth" }
    var minimumRemaining: Double? {
        let values = [remaining5h, remaining7d].compactMap { $0 }
        return values.min()
    }
}

private enum AccountMonitorState {
    case notApplicable
    case unavailable
    case notLoggedIn
    case skipped
    case refreshing
    case active
    case failed(String)
}

private struct AccountMonitorSnapshot {
    var state: AccountMonitorState
    var balance: Double?
    var key: ExternalKeySnapshot?
    var channel: ChannelSnapshot?
}

private struct AccountListEntry {
    let account: AccountSnapshot
    let isCurrent: Bool
    let monitor: AccountMonitorSnapshot
    let isScheduleUpdating: Bool
}

private struct ChannelSnapshot {
    let name: String
    let status: String
    let latencyMs: Double?
    let pingMs: Double?
    let availability: Double?
}

private struct ExternalKeySnapshot {
    let name: String
    let group: String
    let rateMultiplier: Double
    let currentConcurrency: Int?
}

private func formatRateMultiplier(_ value: Double) -> String {
    var text = String(format: "%.6f", value)
    while text.last == "0" { text.removeLast() }
    if text.last == "." { text.removeLast() }
    return text + "x"
}

private func parseTimestamp(_ value: String) -> Date? {
    let isoFormatter = ISO8601DateFormatter()
    isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return isoFormatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
}

private func formatCompactTimestamp(_ value: String) -> String {
    let date = parseTimestamp(value)
    guard let date else {
        return value.count > 19 ? String(value.prefix(19)).replacingOccurrences(of: "T", with: " ") : value
    }
    let displayFormatter = DateFormatter()
    displayFormatter.locale = Locale(identifier: "zh_CN")
    displayFormatter.dateFormat = "MM-dd HH:mm:ss"
    return displayFormatter.string(from: date)
}

private class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

private final class AccountRowView: FlippedView {
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let metricLabel = NSTextField(labelWithString: "")
    private let scheduleToggle = NSButton(checkboxWithTitle: "调度", target: nil, action: nil)
    private let monitorButton = NSButton(title: "登录", target: nil, action: nil)
    private let skipButton = NSButton(title: "跳过", target: nil, action: nil)
    private let separator = NSBox()
    private var accountID = 0
    private var schedulable = false
    var onSetSchedulable: ((Int, Bool) -> Void)?
    var onLogin: ((Int) -> Void)?
    var onSkip: ((Int, Bool) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        detailLabel.font = .systemFont(ofSize: 12)
        detailLabel.textColor = .secondaryLabelColor
        metricLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        metricLabel.textColor = .secondaryLabelColor
        metricLabel.lineBreakMode = .byTruncatingTail
        scheduleToggle.font = .systemFont(ofSize: 11)
        scheduleToggle.toolTip = "是否参与 Sub2API 调度"
        scheduleToggle.target = self
        scheduleToggle.action = #selector(scheduleChanged)
        monitorButton.bezelStyle = .inline
        monitorButton.controlSize = .small
        monitorButton.target = self
        monitorButton.action = #selector(loginPressed)
        skipButton.bezelStyle = .inline
        skipButton.controlSize = .small
        skipButton.target = self
        skipButton.action = #selector(skipPressed)
        separator.boxType = .separator
        [titleLabel, detailLabel, metricLabel, scheduleToggle, monitorButton, skipButton, separator].forEach(addSubview)
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        let rightWidth: CGFloat = 108
        let textWidth = max(120, bounds.width - rightWidth - 18)
        titleLabel.frame = NSRect(x: 8, y: 7, width: textWidth, height: 18)
        detailLabel.frame = NSRect(x: 8, y: 27, width: textWidth, height: 16)
        metricLabel.frame = NSRect(x: 8, y: 47, width: bounds.width - 16, height: 16)
        scheduleToggle.frame = NSRect(x: bounds.width - rightWidth, y: 5, width: rightWidth, height: 20)
        monitorButton.frame = NSRect(x: bounds.width - rightWidth, y: 28, width: 55, height: 20)
        skipButton.frame = NSRect(x: bounds.width - 51, y: 28, width: 47, height: 20)
        separator.frame = NSRect(x: 8, y: bounds.height - 1, width: bounds.width - 16, height: 1)
    }

    func configure(with entry: AccountListEntry) {
        let account = entry.account
        accountID = account.id
        schedulable = account.schedulable
        titleLabel.stringValue = (entry.isCurrent ? "● " : "") + account.name
        titleLabel.textColor = entry.isCurrent ? .systemBlue : .labelColor
        let type = account.isSubscription ? "OAuth" : "API Key"
        detailLabel.stringValue = "\(type) · \(localizedAccountStatus(account.status)) · 并发 \(account.currentConcurrency)/\(account.concurrency)"
        scheduleToggle.state = account.schedulable ? .on : .off
        scheduleToggle.isEnabled = !entry.isScheduleUpdating
        scheduleToggle.title = entry.isScheduleUpdating ? "更新中" : "调度"

        if account.isSubscription {
            let quota5h = account.remaining5h.map { String(format: "5h %.0f%%", $0) } ?? "5h --"
            let quota7d = account.remaining7d.map { String(format: "7d %.0f%%", $0) } ?? "7d --"
            metricLabel.stringValue = "\(quota5h) · \(quota7d)\(lastUsedText(account.lastUsedAt))"
            monitorButton.isHidden = true
            skipButton.isHidden = true
            return
        }

        monitorButton.isHidden = false
        switch entry.monitor.state {
        case .notApplicable, .unavailable:
            metricLabel.stringValue = "未发现第三方监控地址\(lastUsedText(account.lastUsedAt))"
            monitorButton.isHidden = true
            skipButton.isHidden = true
        case .notLoggedIn:
            metricLabel.stringValue = "未登录第三方监控\(lastUsedText(account.lastUsedAt))"
            monitorButton.title = "登录"
            skipButton.title = "跳过"
            skipButton.isHidden = false
        case .skipped:
            metricLabel.stringValue = "已跳过第三方监控\(lastUsedText(account.lastUsedAt))"
            monitorButton.title = "启用"
            skipButton.isHidden = true
        case .refreshing:
            metricLabel.stringValue = "正在刷新第三方数据..."
            monitorButton.title = "登录"
            monitorButton.isEnabled = false
            skipButton.isHidden = true
        case .active:
            let balance = entry.monitor.balance.map { String(format: "$%.2f", $0) } ?? "$--"
            let multiplier = entry.monitor.key.map { formatRateMultiplier($0.rateMultiplier) } ?? "--x"
            let ping = entry.monitor.channel?.pingMs.map { "PING \(Int($0))ms" } ?? "PING --"
            let availability = entry.monitor.channel?.availability.map { String(format: "可用 %.1f%%", $0) } ?? "可用 --"
            metricLabel.stringValue = "\(balance) · \(multiplier) · \(ping) · \(availability)"
            monitorButton.title = "重登"
            monitorButton.isEnabled = true
            skipButton.title = "跳过"
            skipButton.isHidden = false
        case .failed(let message):
            metricLabel.stringValue = message
            monitorButton.title = "重登"
            monitorButton.isEnabled = true
            skipButton.title = "跳过"
            skipButton.isHidden = false
        }
    }

    private func localizedAccountStatus(_ status: String) -> String {
        ["active": "正常", "inactive": "停用", "error": "异常", "paused": "暂停"][status.lowercased()] ?? status
    }

    private func lastUsedText(_ value: String?) -> String {
        value.map { " · 最近 \(formatCompactTimestamp($0))" } ?? ""
    }

    @objc private func scheduleChanged() {
        scheduleToggle.state = schedulable ? .on : .off
        onSetSchedulable?(accountID, !schedulable)
    }

    @objc private func loginPressed() { onLogin?(accountID) }
    @objc private func skipPressed() { onSkip?(accountID, true) }
}

private final class AIDashboardViewController: NSViewController {
    private let ttftValue = NSTextField(labelWithString: "--")
    private let usageDetail = NSTextField(labelWithString: "等待 Sub2API 登录")
    private let accountMetricTitle = NSTextField(labelWithString: "上游余额")
    private let balanceValue = NSTextField(labelWithString: "--")
    private let channelTitle = NSTextField(labelWithString: "渠道")
    private let channelValue = NSTextField(labelWithString: "等待上游数据")
    private let updateValue = NSTextField(labelWithString: "尚未更新")
    private let recentStack = NSStackView()
    private let contentScroll = NSScrollView()
    private let contentDocument = FlippedView()
    private let overviewView = NSView()
    private let accountListView = FlippedView()
    private let accountCountLabel = NSTextField(labelWithString: "上游账户")
    private var accountRows: [AccountRowView] = []
    var onRefresh: (() -> Void)?
    var onLoginSub2API: (() -> Void)?
    var onLoginUpstream: (() -> Void)?
    var onOpenUsage: (() -> Void)?
    var onQuit: (() -> Void)?
    var onSetSchedulable: ((Int, Bool) -> Void)?
    var onLoginAccount: ((Int) -> Void)?
    var onSkipAccount: ((Int, Bool) -> Void)?

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 645))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        contentScroll.frame = NSRect(x: 0, y: 38, width: 360, height: 607)
        contentScroll.hasVerticalScroller = true
        contentScroll.autohidesScrollers = true
        contentScroll.borderType = .noBorder
        contentScroll.drawsBackground = false
        contentScroll.documentView = contentDocument
        contentDocument.frame = NSRect(x: 0, y: 0, width: 360, height: 390)
        overviewView.frame = NSRect(x: 0, y: 0, width: 360, height: 355)
        accountListView.frame = NSRect(x: 10, y: 355, width: 340, height: 35)
        contentDocument.addSubview(overviewView)
        contentDocument.addSubview(accountListView)
        container.addSubview(contentScroll)

        let title = NSTextField(labelWithString: "AI 延迟")
        title.font = .systemFont(ofSize: 16, weight: .semibold)
        ttftValue.font = .monospacedDigitSystemFont(ofSize: 34, weight: .semibold)
        ttftValue.textColor = .systemBlue
        usageDetail.font = .systemFont(ofSize: 13)
        usageDetail.textColor = .secondaryLabelColor
        usageDetail.maximumNumberOfLines = 2

        let latencyBox = boxView()
        addViews([title, ttftValue, usageDetail], to: latencyBox)
        title.frame = NSRect(x: 14, y: 99, width: 150, height: 22)
        ttftValue.frame = NSRect(x: 14, y: 49, width: 312, height: 44)
        usageDetail.frame = NSRect(x: 14, y: 8, width: 312, height: 38)

        accountMetricTitle.font = .systemFont(ofSize: 13, weight: .medium)
        balanceValue.font = .monospacedDigitSystemFont(ofSize: 21, weight: .semibold)
        balanceValue.maximumNumberOfLines = 2
        balanceValue.lineBreakMode = .byWordWrapping
        balanceValue.cell?.wraps = true
        balanceValue.cell?.usesSingleLineMode = false
        channelTitle.font = .systemFont(ofSize: 13, weight: .medium)
        channelValue.font = .systemFont(ofSize: 13)
        channelValue.maximumNumberOfLines = 3
        channelValue.textColor = .secondaryLabelColor
        let statusBox = boxView()
        addViews([accountMetricTitle, balanceValue, channelTitle, channelValue], to: statusBox)
        accountMetricTitle.frame = NSRect(x: 14, y: 72, width: 156, height: 20)
        balanceValue.frame = NSRect(x: 14, y: 15, width: 156, height: 52)
        channelTitle.frame = NSRect(x: 178, y: 72, width: 148, height: 20)
        channelValue.lineBreakMode = .byWordWrapping
        channelValue.cell?.wraps = true
        channelValue.cell?.usesSingleLineMode = false
        channelValue.frame = NSRect(x: 178, y: 7, width: 148, height: 62)

        let recentTitle = label("最近首字延迟", size: 13, weight: .medium)
        recentStack.orientation = .horizontal
        recentStack.distribution = .fillEqually
        recentStack.spacing = 4
        let recentBox = boxView()
        addViews([recentTitle, recentStack], to: recentBox)
        recentTitle.frame = NSRect(x: 14, y: 40, width: 150, height: 20)
        recentStack.frame = NSRect(x: 12, y: 6, width: 316, height: 28)
        setRecent([])

        latencyBox.frame = NSRect(x: 10, y: 213, width: 340, height: 129)
        statusBox.frame = NSRect(x: 10, y: 106, width: 340, height: 97)
        recentBox.frame = NSRect(x: 10, y: 33, width: 340, height: 63)
        overviewView.addSubview(latencyBox)
        overviewView.addSubview(statusBox)
        overviewView.addSubview(recentBox)

        accountCountLabel.frame = NSRect(x: 4, y: 6, width: 332, height: 20)
        accountCountLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        accountListView.addSubview(accountCountLabel)

        let actions: [(String, String, Selector)] = [
            ("arrow.clockwise", "立即刷新", #selector(refreshPressed)),
            ("person.badge.key", "登录 Sub2API", #selector(loginSubPressed)),
            ("key", "登录当前上游", #selector(loginUpstreamPressed)),
            ("safari", "打开使用记录", #selector(openUsagePressed)),
            ("power", "退出 AI 监控", #selector(quitPressed)),
        ]
        for (index, action) in actions.enumerated() {
            let image = NSImage(systemSymbolName: action.0, accessibilityDescription: action.1) ?? NSImage()
            let button = NSButton(image: image, target: self, action: action.2)
            button.frame = NSRect(x: 10 + CGFloat(index) * 34, y: 4, width: 30, height: 28)
            button.isBordered = false
            button.toolTip = action.1
            container.addSubview(button)
        }
        updateValue.frame = NSRect(x: 228, y: 9, width: 122, height: 16)
        updateValue.alignment = .right
        updateValue.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        updateValue.textColor = .tertiaryLabelColor
        container.addSubview(updateValue)
        view = container
    }

    func update(usage: UsageSnapshot?, account: AccountSnapshot?, balance: Double?, channel: ChannelSnapshot?, externalKey: ExternalKeySnapshot?, recent: [Double], accounts: [AccountListEntry], updatedAt: Date?, error: String?) {
        if let usage {
            ttftValue.stringValue = formatDuration(usage.firstTokenMs)
            let total = usage.durationMs.map { " · 总 \(formatDuration($0))" } ?? ""
            usageDetail.stringValue = "\(usage.account) · \(usage.model) · \(usage.group)\n\(formatCompactTimestamp(usage.createdAt))\(total)"
        }
        if let account, account.isSubscription {
            accountMetricTitle.stringValue = "\(account.name) 剩余额度"
            balanceValue.font = .monospacedDigitSystemFont(ofSize: 16, weight: .semibold)
            let remaining5h = account.remaining5h.map { String(format: "5h %.0f%%", $0) } ?? "5h --"
            let remaining7d = account.remaining7d.map { String(format: "7d %.0f%%", $0) } ?? "7d --"
            balanceValue.stringValue = "\(remaining5h)\n\(remaining7d)"
            channelTitle.stringValue = "订阅账户"
            let status = localizedStatus(account.status)
            channelValue.stringValue = "\(status)\nOAuth 订阅\n#\(account.id)"
        } else {
            accountMetricTitle.stringValue = "\(account?.name ?? "上游") 余额"
            balanceValue.font = .monospacedDigitSystemFont(ofSize: 21, weight: .semibold)
            balanceValue.stringValue = balance.map { String(format: "$%.2f", $0) } ?? "--"
            let group = externalKey?.group ?? "gpt"
            let multiplier = externalKey.map { " · \(formatRateMultiplier($0.rateMultiplier))" } ?? ""
            channelTitle.stringValue = group + multiplier
            if balance == nil, externalKey == nil, channel == nil {
                channelValue.stringValue = "未登录第三方监控\n点击钥匙按钮登录"
            } else {
                updateExternalChannel(channel, externalKey: externalKey)
            }
        }
        setRecent(recent)
        updateAccounts(accounts)
        if let error { updateValue.stringValue = error }
        else if let updatedAt {
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm:ss"
            updateValue.stringValue = formatter.string(from: updatedAt)
        }
    }

    private func updateExternalChannel(_ channel: ChannelSnapshot?, externalKey: ExternalKeySnapshot?) {
        if let channel {
            let status = localizedStatus(channel.status)
            let concurrency = externalKey?.currentConcurrency.map { " · 并发 \($0)" } ?? ""
            let latency = channel.latencyMs.map { "对话 \(formatDuration($0))" } ?? "对话 --"
            let ping = channel.pingMs.map { "PING \(Int($0))ms" } ?? "PING --"
            let availability = channel.availability.map { String(format: "7天可用性 %.2f%%", $0) } ?? "7天可用性 --"
            channelValue.stringValue = "\(status)\(concurrency)\n\(latency) · \(ping)\n\(availability)"
        } else {
            channelValue.stringValue = "等待渠道数据"
        }
    }

    private func localizedStatus(_ status: String) -> String {
        [
            "active": "正常",
            "operational": "正常",
            "degraded": "降级",
            "failed": "失败",
            "error": "错误",
            "paused": "暂停",
            "unknown": "未知",
        ][status.lowercased()] ?? status
    }

    private func setRecent(_ values: [Double]) {
        recentStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let shown = Array(values.suffix(5))
        for index in 0..<5 {
            let text = index < shown.count ? formatRecentDuration(shown[index]) : "--"
            let field = NSTextField(labelWithString: text)
            field.alignment = .center
            field.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
            field.wantsLayer = true
            field.layer?.cornerRadius = 4
            field.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
            recentStack.addArrangedSubview(field)
        }
    }

    private func formatDuration(_ milliseconds: Double) -> String {
        milliseconds >= 1000 ? String(format: "%.2fs", milliseconds / 1000) : "\(Int(milliseconds))ms"
    }

    private func formatRecentDuration(_ milliseconds: Double) -> String {
        String(format: "%.1fs", milliseconds / 1000)
    }

    private func updateAccounts(_ entries: [AccountListEntry]) {
        accountCountLabel.stringValue = "上游账户 · \(entries.count)"
        let rowHeight: CGFloat = 68
        let previousOrigin = contentScroll.contentView.bounds.origin
        accountRows.forEach { $0.removeFromSuperview() }
        accountRows.removeAll()
        let listHeight = 32 + CGFloat(entries.count) * rowHeight
        accountListView.frame = NSRect(x: 10, y: 355, width: 340, height: listHeight)
        contentDocument.frame = NSRect(x: 0, y: 0, width: 360, height: 355 + listHeight + 10)
        for (index, entry) in entries.enumerated() {
            let row = AccountRowView(frame: NSRect(x: 0, y: 32 + CGFloat(index) * rowHeight, width: 340, height: rowHeight))
            row.autoresizingMask = [.width]
            row.onSetSchedulable = { [weak self] id, enabled in self?.onSetSchedulable?(id, enabled) }
            row.onLogin = { [weak self] id in self?.onLoginAccount?(id) }
            row.onSkip = { [weak self] id, skipped in self?.onSkipAccount?(id, skipped) }
            row.configure(with: entry)
            accountListView.addSubview(row)
            accountRows.append(row)
        }
        contentDocument.layoutSubtreeIfNeeded()
        let maxY = max(0, contentDocument.bounds.height - contentScroll.contentView.bounds.height)
        contentScroll.contentView.scroll(to: NSPoint(x: 0, y: min(previousOrigin.y, maxY)))
        contentScroll.reflectScrolledClipView(contentScroll.contentView)
    }

    private func boxView() -> NSView {
        let box = NSView()
        box.wantsLayer = true
        box.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        box.layer?.cornerRadius = 6
        box.layer?.borderWidth = 1
        box.layer?.borderColor = NSColor.separatorColor.cgColor
        return box
    }

    private func label(_ text: String, size: CGFloat, weight: NSFont.Weight) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: size, weight: weight)
        return field
    }

    private func addViews(_ views: [NSView], to parent: NSView) { views.forEach(parent.addSubview) }
    @objc private func refreshPressed() { onRefresh?() }
    @objc private func loginSubPressed() { onLoginSub2API?() }
    @objc private func loginUpstreamPressed() { onLoginUpstream?() }
    @objc private func openUsagePressed() { onOpenUsage?() }
    @objc private func quitPressed() { onQuit?() }
}

private final class AppDelegate: NSObject, NSApplicationDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private let dashboard = AIDashboardViewController()
    private let tokenStore = KeychainTokenStore()
    private var config: AIConfig?
    private var subClient: AuthenticatedAPIClient?
    private var timers: [Timer] = []
    private var clickMonitor: Any?
    private var loginWindows: [String: LoginWindowController] = [:]
    private var usage: UsageSnapshot?
    private var account: AccountSnapshot?
    private var channel: ChannelSnapshot?
    private var externalKey: ExternalKeySnapshot?
    private var balance: Double?
    private var accounts: [AccountSnapshot] = []
    private var accountItems: [Int: [String: Any]] = [:]
    private var upstreamsByAccountID: [Int: UpstreamConfig] = [:]
    private var accountMonitors: [Int: AccountMonitorSnapshot] = [:]
    private var scheduleUpdatesInFlight: Set<Int> = []
    private var monitorQueue: [Int] = []
    private var monitorRequestsInFlight: Set<Int> = []
    private var recentTTFT: [Double] = []
    private var updatedAt: Date?
    private var lastError: String?
    private var accountRequestInFlight = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusItem.button?.title = "AI --"
        statusItem.button?.toolTip = "AI 首字延迟"
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover)
        statusItem.button?.sendAction(on: [.leftMouseDown])
        popover.behavior = .transient
        popover.animates = false
        popover.contentSize = NSSize(width: 360, height: 645)
        popover.contentViewController = dashboard
        _ = dashboard.view
        dashboard.onRefresh = { [weak self] in self?.refreshAll() }
        dashboard.onLoginSub2API = { [weak self] in self?.showLogin(for: self?.config?.sub2api) }
        dashboard.onLoginUpstream = { [weak self] in
            guard let self, let accountID = self.usage?.accountID else { return }
            self.loginToAccountMonitor(accountID: accountID)
        }
        dashboard.onOpenUsage = { [weak self] in self?.openUsage() }
        dashboard.onQuit = { NSApp.terminate(nil) }
        dashboard.onSetSchedulable = { [weak self] id, enabled in self?.requestSchedulableChange(accountID: id, enabled: enabled) }
        dashboard.onLoginAccount = { [weak self] id in self?.loginToAccountMonitor(accountID: id) }
        dashboard.onSkipAccount = { [weak self] id, skipped in self?.setAccountMonitorSkipped(accountID: id, skipped: skipped) }
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            DispatchQueue.main.async { if self?.popover.isShown == true { self?.popover.performClose(nil) } }
        }

        do {
            let loaded = try loadConfig()
            config = loaded
            _ = tokenStore.load(site: loaded.sub2api.name)
            for upstream in loaded.upstreamOverrides {
                _ = tokenStore.load(site: upstream.site.name)
            }
            subClient = AuthenticatedAPIClient(site: loaded.sub2api, timeout: loaded.httpTimeout, tokens: tokenStore)
            scheduleTimers(loaded)
            refreshAll()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                self?.showFirstMissingLogin()
            }
        } catch {
            showError("配置错误")
            statusItem.button?.toolTip = error.localizedDescription
        }
    }

    private func loadConfig() throws -> AIConfig {
        let path = NSString(string: "~/Library/Application Support/Sub2APIMenuBar/config.json").expandingTildeInPath
        return try JSONDecoder().decode(AIConfig.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
    }

    private func scheduleTimers(_ config: AIConfig) {
        let definitions: [(Double, () -> Void)] = [
            (config.usageInterval, { [weak self] in self?.refreshUsage() }),
            (config.channelInterval, { [weak self] in self?.refreshAccounts() }),
            (config.balanceInterval, { [weak self] in self?.refreshAccountMonitors() }),
        ]
        for (interval, action) in definitions {
            let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in action() }
            RunLoop.main.add(timer, forMode: .common)
            timers.append(timer)
        }
    }

    private func refreshAll() {
        refreshUsage()
        refreshAccounts()
    }

    private func refreshUsage() {
        guard let config, let subClient else { return }
        var query = [
            URLQueryItem(name: "page", value: "1"),
            URLQueryItem(name: "page_size", value: "20"),
            URLQueryItem(name: "sort_by", value: "created_at"),
            URLQueryItem(name: "sort_order", value: "desc"),
        ]
        if let userID = config.tracked_user_id {
            query.append(URLQueryItem(name: "user_id", value: String(userID)))
        }
        if let apiKeyID = config.tracked_api_key_id {
            query.append(URLQueryItem(name: "api_key_id", value: String(apiKeyID)))
        }
        subClient.get(path: "/api/v1/admin/usage", query: query) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success(let object):
                    guard let item = self.items(from: object).first(where: { self.matchesUsage($0, config: config) }) else {
                        self.showError("没有匹配的使用记录")
                        return
                    }
                    guard let firstToken = self.number(item, keys: ["first_token_ms", "ttft_ms"]) else {
                        self.showError("使用记录缺少首字延迟")
                        return
                    }
                    let account = self.nestedString(item, paths: [["account", "name"], ["account_name"]]) ?? "--"
                    guard let accountIDValue = self.number(item, keys: ["account_id"])
                            ?? (item["account"] as? [String: Any]).flatMap({ self.number($0, keys: ["id"]) }) else {
                        self.showError("使用记录缺少账户 ID")
                        return
                    }
                    let snapshot = UsageSnapshot(
                        accountID: Int(accountIDValue),
                        account: account,
                        model: self.string(item, keys: ["model", "requested_model"]) ?? "--",
                        group: self.nestedString(item, paths: [["group", "name"], ["group_name"]]) ?? "--",
                        firstTokenMs: firstToken,
                        durationMs: self.number(item, keys: ["duration_ms", "total_duration_ms"]),
                        createdAt: self.string(item, keys: ["created_at", "time"]) ?? "--"
                    )
                    if self.usage?.createdAt != snapshot.createdAt {
                        self.recentTTFT.append(snapshot.firstTokenMs)
                        self.recentTTFT = Array(self.recentTTFT.suffix(5))
                    }
                    if self.account?.id != snapshot.accountID {
                        self.account = nil
                        self.balance = nil
                        self.channel = nil
                        self.externalKey = nil
                    }
                    self.usage = snapshot
                    self.refreshAccountIfNeeded(id: snapshot.accountID)
                    self.markUpdated()
                case .failure(let error): self.showError(error.localizedDescription)
                }
            }
        }
    }

    private func refreshAccounts() {
        guard !accountRequestInFlight, let subClient else { return }
        accountRequestInFlight = true
        let query = [
            URLQueryItem(name: "page", value: "1"),
            URLQueryItem(name: "page_size", value: "200"),
            URLQueryItem(name: "sort_by", value: "name"),
            URLQueryItem(name: "sort_order", value: "asc"),
        ]
        subClient.get(path: "/api/v1/admin/accounts", query: query) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.accountRequestInFlight = false
                switch result {
                case .success(let object):
                    let sourceItems = self.items(from: object)
                    var snapshots: [AccountSnapshot] = []
                    var rawItems: [Int: [String: Any]] = [:]
                    var discoveredUpstreams: [Int: UpstreamConfig] = [:]
                    for item in sourceItems {
                        guard let snapshot = self.accountSnapshot(from: item) else { continue }
                        snapshots.append(snapshot)
                        rawItems[snapshot.id] = item
                        if !snapshot.isSubscription, let upstream = self.upstreamConfig(for: snapshot, item: item) {
                            discoveredUpstreams[snapshot.id] = upstream
                        }
                    }
                    self.accounts = snapshots
                    self.accountItems = rawItems
                    self.upstreamsByAccountID = discoveredUpstreams
                    self.reconcileAccountMonitorStates()
                    self.syncCurrentAccountDetails()
                    self.markUpdated()
                    self.refreshAccountMonitors()
                case .failure(let error):
                    self.showError(error.localizedDescription)
                }
            }
        }
    }

    private func accountSnapshot(from item: [String: Any]) -> AccountSnapshot? {
        guard let id = number(item, keys: ["id"]).map(Int.init) else { return nil }
        let extra = item["extra"] as? [String: Any] ?? [:]
        let used5h = number(extra, keys: ["codex_5h_used_percent", "codex_secondary_used_percent"])
        let used7d = number(extra, keys: ["codex_7d_used_percent", "codex_primary_used_percent"])
        return AccountSnapshot(
            id: id,
            name: string(item, keys: ["name"]) ?? "#\(id)",
            type: string(item, keys: ["type"]) ?? "unknown",
            status: string(item, keys: ["status"]) ?? "unknown",
            schedulable: bool(item, keys: ["schedulable"]) ?? true,
            concurrency: number(item, keys: ["concurrency"]).map(Int.init) ?? 0,
            currentConcurrency: number(item, keys: ["current_concurrency"]).map(Int.init) ?? 0,
            rateMultiplier: number(item, keys: ["rate_multiplier"]) ?? 1,
            lastUsedAt: string(item, keys: ["last_used_at"]),
            remaining5h: used5h.map { max(0, min(100, 100 - $0)) },
            remaining7d: used7d.map { max(0, min(100, 100 - $0)) }
        )
    }

    private func upstreamConfig(for account: AccountSnapshot, item: [String: Any]) -> UpstreamConfig? {
        guard let config else { return nil }
        return config.upstreamOverrides.first { $0.matches(accountName: account.name) }
            ?? discoverUpstream(accountName: account.name, accountItem: item)
    }

    private func reconcileAccountMonitorStates() {
        let validIDs = Set(accounts.map(\.id))
        accountMonitors = accountMonitors.filter { validIDs.contains($0.key) }
        for account in accounts {
            if account.isSubscription {
                accountMonitors[account.id] = AccountMonitorSnapshot(state: .notApplicable, balance: nil, key: nil, channel: nil)
            } else if upstreamsByAccountID[account.id] == nil {
                accountMonitors[account.id] = AccountMonitorSnapshot(state: .unavailable, balance: nil, key: nil, channel: nil)
            } else if isAccountMonitorSkipped(accountID: account.id) {
                accountMonitors[account.id] = AccountMonitorSnapshot(state: .skipped, balance: nil, key: nil, channel: nil)
            } else if let upstream = upstreamsByAccountID[account.id], tokenStore.load(site: upstream.site.name) == nil {
                accountMonitors[account.id] = AccountMonitorSnapshot(state: .notLoggedIn, balance: nil, key: nil, channel: nil)
            } else if accountMonitors[account.id] == nil {
                accountMonitors[account.id] = AccountMonitorSnapshot(state: .refreshing, balance: nil, key: nil, channel: nil)
            }
        }
    }

    private func refreshAccountMonitors() {
        for account in accounts where !account.isSubscription {
            guard let upstream = upstreamsByAccountID[account.id],
                  !isAccountMonitorSkipped(accountID: account.id),
                  tokenStore.load(site: upstream.site.name) != nil,
                  !monitorRequestsInFlight.contains(account.id),
                  !monitorQueue.contains(account.id) else { continue }
            accountMonitors[account.id] = AccountMonitorSnapshot(
                state: .refreshing,
                balance: accountMonitors[account.id]?.balance,
                key: accountMonitors[account.id]?.key,
                channel: accountMonitors[account.id]?.channel
            )
            monitorQueue.append(account.id)
        }
        updateUI()
        pumpMonitorQueue()
    }

    private func pumpMonitorQueue() {
        while monitorRequestsInFlight.count < 3, !monitorQueue.isEmpty {
            let accountID = monitorQueue.removeFirst()
            guard !isAccountMonitorSkipped(accountID: accountID) else { continue }
            monitorRequestsInFlight.insert(accountID)
            refreshMonitor(accountID: accountID)
        }
    }

    private func refreshMonitor(accountID: Int) {
        guard let upstream = upstreamsByAccountID[accountID],
              let account = accounts.first(where: { $0.id == accountID }),
              let config else {
            finishMonitorRefresh(accountID: accountID, result: .failure(MonitorError.invalidResponse("缺少中转配置")))
            return
        }
        let client = AuthenticatedAPIClient(site: upstream.site, timeout: config.httpTimeout, tokens: tokenStore)
        client.get(path: "/api/v1/auth/me") { [weak self] balanceResult in
            guard let self else { return }
            switch balanceResult {
            case .failure(let error):
                self.finishMonitorRefresh(accountID: accountID, result: .failure(error))
            case .success(let balanceObject):
                guard let balanceData = balanceObject as? [String: Any],
                      let balance = self.number(balanceData, keys: ["balance"]) else {
                    self.finishMonitorRefresh(accountID: accountID, result: .failure(MonitorError.invalidResponse("余额响应无法解析")))
                    return
                }
                let query = [URLQueryItem(name: "page", value: "1"), URLQueryItem(name: "page_size", value: "100")]
                client.get(path: "/api/v1/keys", query: query) { [weak self] keyResult in
                    guard let self else { return }
                    switch keyResult {
                    case .failure(let error):
                        self.finishMonitorRefresh(accountID: accountID, result: .failure(error))
                    case .success(let keyObject):
                        let keyName = upstream.key_name ?? account.name
                        guard let item = self.items(from: keyObject).first(where: {
                            self.string($0, keys: ["name"])?.caseInsensitiveCompare(keyName) == .orderedSame
                        }), let group = item["group"] as? [String: Any],
                           let multiplier = self.number(group, keys: ["rate_multiplier"]) else {
                            self.finishMonitorRefresh(accountID: accountID, result: .failure(MonitorError.invalidResponse("找不到同名密钥或分组")))
                            return
                        }
                        let key = ExternalKeySnapshot(
                            name: self.string(item, keys: ["name"]) ?? keyName,
                            group: self.string(group, keys: ["name"]) ?? upstream.channel_group ?? "--",
                            rateMultiplier: multiplier,
                            currentConcurrency: self.number(item, keys: ["current_concurrency"]).map(Int.init)
                        )
                        client.get(path: "/api/v1/channel-monitors") { [weak self] channelResult in
                            guard let self else { return }
                            switch channelResult {
                            case .failure(let error):
                                self.finishMonitorRefresh(accountID: accountID, result: .failure(error))
                            case .success(let channelObject):
                                guard let channelItem = self.items(from: channelObject).first(where: {
                                    self.string($0, keys: ["name", "group_name", "group"])?.caseInsensitiveCompare(key.group) == .orderedSame
                                }) else {
                                    self.finishMonitorRefresh(accountID: accountID, result: .failure(MonitorError.invalidResponse("找不到渠道 \(key.group)")))
                                    return
                                }
                                let channel = ChannelSnapshot(
                                    name: self.string(channelItem, keys: ["name", "group_name"]) ?? key.group,
                                    status: self.string(channelItem, keys: ["status", "primary_status", "health_status"]) ?? "unknown",
                                    latencyMs: self.number(channelItem, keys: ["latency_ms", "primary_latency_ms", "dialog_latency_ms"]),
                                    pingMs: self.number(channelItem, keys: ["primary_ping_latency_ms", "ping_latency_ms", "ping_ms", "endpoint_ping_ms", "endpoint_latency_ms"]),
                                    availability: self.number(channelItem, keys: ["availability_7d", "availability", "success_rate"])
                                )
                                self.finishMonitorRefresh(
                                    accountID: accountID,
                                    result: .success(AccountMonitorSnapshot(state: .active, balance: balance, key: key, channel: channel))
                                )
                            }
                        }
                    }
                }
            }
        }
    }

    private func finishMonitorRefresh(accountID: Int, result: Result<AccountMonitorSnapshot, Error>) {
        DispatchQueue.main.async {
            self.monitorRequestsInFlight.remove(accountID)
            if self.isAccountMonitorSkipped(accountID: accountID) {
                self.accountMonitors[accountID] = AccountMonitorSnapshot(state: .skipped, balance: nil, key: nil, channel: nil)
            } else {
                switch result {
                case .success(let snapshot):
                    self.accountMonitors[accountID] = snapshot
                case .failure(let error):
                    let previous = self.accountMonitors[accountID]
                    self.accountMonitors[accountID] = AccountMonitorSnapshot(
                        state: error is MonitorError ? .failed(error.localizedDescription) : .failed("监控失败：\(error.localizedDescription)"),
                        balance: previous?.balance,
                        key: previous?.key,
                        channel: previous?.channel
                    )
                }
            }
            self.syncCurrentAccountDetails()
            self.updateUI()
            self.pumpMonitorQueue()
        }
    }

    private func syncCurrentAccountDetails() {
        guard let usage, let current = accounts.first(where: { $0.id == usage.accountID }) else { return }
        account = current
        let monitor = accountMonitors[current.id]
        balance = monitor?.balance
        externalKey = monitor?.key
        channel = monitor?.channel
    }

    private func monitorPreferenceKey(accountID: Int) -> String {
        "\(config?.sub2api.base_url ?? "")#\(accountID)"
    }

    private func isAccountMonitorSkipped(accountID: Int) -> Bool {
        let values = UserDefaults.standard.stringArray(forKey: "skippedUpstreamMonitors") ?? []
        return values.contains(monitorPreferenceKey(accountID: accountID))
    }

    private func setAccountMonitorSkipped(accountID: Int, skipped: Bool) {
        var values = Set(UserDefaults.standard.stringArray(forKey: "skippedUpstreamMonitors") ?? [])
        let key = monitorPreferenceKey(accountID: accountID)
        if skipped { values.insert(key) } else { values.remove(key) }
        UserDefaults.standard.set(Array(values).sorted(), forKey: "skippedUpstreamMonitors")
        monitorQueue.removeAll { $0 == accountID }
        accountMonitors[accountID] = AccountMonitorSnapshot(
            state: skipped ? .skipped : .notLoggedIn,
            balance: nil,
            key: nil,
            channel: nil
        )
        syncCurrentAccountDetails()
        updateUI()
    }

    private func loginToAccountMonitor(accountID: Int) {
        guard let upstream = upstreamsByAccountID[accountID] else { return }
        if isAccountMonitorSkipped(accountID: accountID) {
            setAccountMonitorSkipped(accountID: accountID, skipped: false)
            if tokenStore.load(site: upstream.site.name) != nil {
                refreshAccountMonitors()
                return
            }
        }
        showLogin(for: upstream.site)
    }

    private func requestSchedulableChange(accountID: Int, enabled: Bool) {
        guard let target = accounts.first(where: { $0.id == accountID }), let subClient else { return }
        if !enabled && accounts.filter({ $0.id != accountID && $0.schedulable }).isEmpty {
            presentAlert(title: "无法暂停调度", message: "至少需要保留一个上游账户参与调度。")
            return
        }
        if !enabled, usage?.accountID == accountID {
            let alert = NSAlert()
            alert.messageText = "暂停当前使用账户？"
            alert.informativeText = "\(target.name) 是最近请求实际使用的账户。暂停后，后续请求将切换到其他可调度账户。"
            alert.alertStyle = .warning
            alert.addButton(withTitle: "暂停调度")
            alert.addButton(withTitle: "取消")
            NSApp.activate(ignoringOtherApps: true)
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        scheduleUpdatesInFlight.insert(accountID)
        updateUI()
        subClient.post(path: "/api/v1/admin/accounts/\(accountID)/schedulable", body: ["schedulable": enabled]) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.scheduleUpdatesInFlight.remove(accountID)
                switch result {
                case .success:
                    self.refreshAccounts()
                case .failure(let error):
                    self.showError("调度更新失败：\(error.localizedDescription)")
                    self.presentAlert(title: "调度状态未修改", message: error.localizedDescription)
                }
                self.updateUI()
            }
        }
    }

    private func presentAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "好")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func matchesUsage(_ item: [String: Any], config: AIConfig) -> Bool {
        if let userID = config.tracked_user_id {
            let actual = number(item, keys: ["user_id"])
                ?? (item["user"] as? [String: Any]).flatMap { number($0, keys: ["id"]) }
            if actual.map(Int.init) != userID { return false }
        }
        if let apiKeyID = config.tracked_api_key_id {
            let actual = number(item, keys: ["api_key_id"])
                ?? (item["api_key"] as? [String: Any]).flatMap { number($0, keys: ["id"]) }
            if actual.map(Int.init) != apiKeyID { return false }
        }
        let group = nestedString(item, paths: [["group", "name"], ["group_name"]])
        guard let trackedGroup = config.tracked_group, !trackedGroup.isEmpty else { return true }
        return group == nil || group?.caseInsensitiveCompare(trackedGroup) == .orderedSame
    }

    private func discoverUpstream(accountName: String, accountItem: [String: Any]) -> UpstreamConfig? {
        guard let credentials = accountItem["credentials"] as? [String: Any],
              let apiBaseURL = string(credentials, keys: ["base_url", "baseUrl"]),
              let monitorBaseURL = originURL(from: apiBaseURL) else { return nil }
        return UpstreamConfig(
            name: accountName,
            account_names: [accountName],
            base_url: monitorBaseURL,
            login_path: "/login",
            key_name: accountName,
            channel_group: nil
        )
    }

    private func originURL(from value: String) -> String? {
        guard let source = URLComponents(string: value),
              let scheme = source.scheme, let host = source.host else { return nil }
        var origin = URLComponents()
        origin.scheme = scheme
        origin.host = host
        origin.port = source.port
        return origin.url?.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private func refreshAccountIfNeeded(id: Int) {
        guard accounts.first(where: { $0.id == id }) == nil else {
            syncCurrentAccountDetails()
            updateUI()
            return
        }
        refreshAccounts()
    }

    private func items(from object: Any) -> [[String: Any]] {
        if let array = object as? [[String: Any]] { return array }
        guard let dictionary = object as? [String: Any] else { return [] }
        for key in ["items", "records", "list", "monitors"] {
            if let array = dictionary[key] as? [[String: Any]] { return array }
        }
        return []
    }

    private func string(_ dictionary: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = dictionary[key] as? String, !value.isEmpty { return value }
            if let value = dictionary[key] as? NSNumber { return value.stringValue }
        }
        return nil
    }

    private func number(_ dictionary: [String: Any], keys: [String]) -> Double? {
        for key in keys { if let value = AuthenticatedAPIClient.double(dictionary[key]) { return value } }
        return nil
    }

    private func bool(_ dictionary: [String: Any], keys: [String]) -> Bool? {
        for key in keys {
            if let value = dictionary[key] as? Bool { return value }
            if let value = dictionary[key] as? NSNumber { return value.boolValue }
            if let value = dictionary[key] as? String {
                if ["true", "1", "yes"].contains(value.lowercased()) { return true }
                if ["false", "0", "no"].contains(value.lowercased()) { return false }
            }
        }
        return nil
    }

    private func nestedString(_ dictionary: [String: Any], paths: [[String]]) -> String? {
        for path in paths {
            var current: Any = dictionary
            for key in path {
                guard let object = current as? [String: Any], let next = object[key] else { current = NSNull(); break }
                current = next
            }
            if let result = current as? String, !result.isEmpty { return result }
        }
        return nil
    }

    private func markUpdated() {
        updatedAt = Date()
        lastError = nil
        updateUI()
    }

    private func showError(_ message: String) {
        lastError = message
        updateUI()
    }

    private func updateUI() {
        if let usage {
            let latency = usage.firstTokenMs >= 1000
                ? String(format: "AI %.1fs", usage.firstTokenMs / 1000)
                : "AI \(Int(usage.firstTokenMs))ms"
            let accountMetric: String
            if account?.isSubscription == true, let remaining = account?.minimumRemaining {
                accountMetric = String(format: " 余%.0f%%", remaining)
            } else if let balance {
                accountMetric = String(format: " $%.2f", balance)
            } else {
                accountMetric = ""
            }
            let multiplier = externalKey.map { " \(formatRateMultiplier($0.rateMultiplier))" } ?? ""
            statusItem.button?.title = latency + accountMetric + multiplier
            statusItem.button?.toolTip = "\(usage.account) · \(usage.model) · 首字延迟 \(Int(usage.firstTokenMs))ms\(accountMetric)\(multiplier)"
        } else {
            statusItem.button?.title = lastError == nil ? "AI --" : "AI !"
            statusItem.button?.toolTip = lastError ?? "等待 AI 延迟数据"
        }
        let sortedAccounts = accounts.sorted { lhs, rhs in
            if lhs.schedulable != rhs.schedulable { return lhs.schedulable }
            if lhs.schedulable {
                let lhsIsCurrent = usage?.accountID == lhs.id
                let rhsIsCurrent = usage?.accountID == rhs.id
                if lhsIsCurrent != rhsIsCurrent { return lhsIsCurrent }
            } else {
                let lhsLastUsed = lhs.lastUsedAt.flatMap(parseTimestamp)
                let rhsLastUsed = rhs.lastUsedAt.flatMap(parseTimestamp)
                if lhsLastUsed != rhsLastUsed {
                    if let lhsLastUsed, let rhsLastUsed { return lhsLastUsed > rhsLastUsed }
                    return lhsLastUsed != nil
                }
            }
            let nameOrder = lhs.name.localizedStandardCompare(rhs.name)
            return nameOrder == .orderedSame ? lhs.id < rhs.id : nameOrder == .orderedAscending
        }
        let entries = sortedAccounts.map { account in
            AccountListEntry(
                account: account,
                isCurrent: usage?.accountID == account.id,
                monitor: accountMonitors[account.id] ?? AccountMonitorSnapshot(state: .unavailable, balance: nil, key: nil, channel: nil),
                isScheduleUpdating: scheduleUpdatesInFlight.contains(account.id)
            )
        }
        dashboard.update(usage: usage, account: account, balance: balance, channel: channel, externalKey: externalKey, recent: recentTTFT, accounts: entries, updatedAt: updatedAt, error: lastError)
    }

    private func showLogin(for site: SiteConfig?) {
        guard let site else { return }
        popover.performClose(nil)
        if let existing = loginWindows[site.name] { existing.show(); return }
        let controller = LoginWindowController(site: site, tokenStore: tokenStore)
        controller.onLogin = { [weak self] in
            self?.refreshAll()
            self?.refreshAccountMonitors()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self?.showFirstMissingLogin()
            }
        }
        controller.onClose = { [weak self, weak controller] in
            guard let self, let controller, self.loginWindows[site.name] === controller else { return }
            self.loginWindows.removeValue(forKey: site.name)
        }
        loginWindows[site.name] = controller
        controller.show()
    }

    private func showFirstMissingLogin() {
        guard let config else { return }
        if tokenStore.load(site: config.sub2api.name) == nil {
            showLogin(for: config.sub2api)
        }
    }

    private func openUsage() {
        guard let config, let url = URL(string: config.sub2api.base_url + "/admin/usage") else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown { popover.performClose(nil) }
        else { popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY) }
    }

    func applicationWillTerminate(_ notification: Notification) {
        timers.forEach { $0.invalidate() }
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
    }
}

private let application = NSApplication.shared
private let delegate = AppDelegate()
application.delegate = delegate
application.run()
