import AppKit
import Foundation
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
    let cache_window_minutes: Double?
    let channel_interval_seconds: Double?
    let balance_interval_seconds: Double?
    let http_timeout_seconds: Double?

    var sub2api: SiteConfig {
        SiteConfig(name: "Sub2API", base_url: sub2api_base_url, login_path: sub2api_login_path ?? "/login")
    }

    var usageInterval: Double { max(3, usage_interval_seconds ?? 10) }
    var cacheWindowMinutes: Double { min(1440, max(1, cache_window_minutes ?? 180)) }
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

private final class TokenStore {
    private let fileURL: URL
    private let lock = NSLock()

    init() {
        let supportDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Sub2APIMenuBar", isDirectory: true)
        fileURL = supportDirectory.appendingPathComponent("credentials.json")
    }

    func load(site: String) -> TokenRecord? {
        lock.lock()
        defer { lock.unlock() }
        return loadAll()[site]
    }

    func save(_ token: TokenRecord, site: String) throws {
        lock.lock()
        defer { lock.unlock() }
        var tokens = loadAll()
        tokens[site] = token
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(tokens)
        try data.write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    private func loadAll() -> [String: TokenRecord] {
        guard let data = try? Data(contentsOf: fileURL) else { return [:] }
        return (try? JSONDecoder().decode([String: TokenRecord].self, from: data)) ?? [:]
    }
}

private final class AuthenticatedAPIClient {
    private let site: SiteConfig
    private let timeout: Double
    private let tokens: TokenStore
    private let session: URLSession

    init(site: SiteConfig, timeout: Double, tokens: TokenStore) {
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
        request.setValue("1", forHTTPHeaderField: "X-User-UI-Request")
        request.setValue("zh-CN", forHTTPHeaderField: "Accept-Language")
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

private protocol APIClient {
    func get(path: String, query: [URLQueryItem], completion: @escaping (Result<Any, Error>) -> Void)
}

private extension APIClient {
    func get(path: String, completion: @escaping (Result<Any, Error>) -> Void) {
        get(path: path, query: [], completion: completion)
    }
}

extension AuthenticatedAPIClient: APIClient {}

private final class WebKitAPIClient: NSObject, WKNavigationDelegate, APIClient {
    private let site: SiteConfig
    private let webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
    private var ready = false
    private var loading = false
    private var pending: [(String, [URLQueryItem], (Result<Any, Error>) -> Void)] = []

    init(site: SiteConfig, timeout: Double) {
        self.site = site
        super.init()
        webView.navigationDelegate = self
    }

    func start() {
        guard !loading else { return }
        loading = true
        guard let url = URL(string: site.base_url + site.login_path) else {
            failPending(MonitorError.invalidResponse("无效接口地址"))
            return
        }
        webView.load(URLRequest(url: url))
    }

    func get(path: String, query: [URLQueryItem] = [], completion: @escaping (Result<Any, Error>) -> Void) {
        if !ready {
            pending.append((path, query, completion))
            start()
            return
        }
        request(path: path, query: query, completion: completion)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        ready = true
        let requests = pending
        pending.removeAll()
        for (path, query, completion) in requests {
            request(path: path, query: query, completion: completion)
        }
    }

    private func request(path: String, query: [URLQueryItem], completion: @escaping (Result<Any, Error>) -> Void) {
        guard var components = URLComponents(string: site.base_url + path) else {
            completion(.failure(MonitorError.invalidResponse("无效接口地址")))
            return
        }
        components.queryItems = query.isEmpty ? nil : query
        guard let url = components.url else {
            completion(.failure(MonitorError.invalidResponse("无效接口地址")))
            return
        }
        let script = """
        const response = await fetch(url, {
          method: 'GET',
          credentials: 'include',
          headers: {
            'Authorization': 'Bearer ' + String(localStorage.getItem('auth_token') || '').replace(/^Bearer\\s+/i, ''),
            'Accept': 'application/json',
            'X-User-UI-Request': '1',
            'Accept-Language': 'zh-CN'
          }
        });
        return { status: response.status, body: await response.text() };
        """
        webView.callAsyncJavaScript(
            script,
            arguments: ["url": url.absoluteString],
            in: nil,
            in: WKContentWorld.page
        ) { result in
            switch result {
            case .failure(let error):
                completion(.failure(error))
                return
            case .success(let value):
                guard let payload = value as? [String: Any],
                      let status = (payload["status"] as? NSNumber)?.intValue,
                      let body = payload["body"] as? String else {
                    completion(.failure(MonitorError.invalidResponse("接口响应无法读取")))
                    return
                }
                guard (200..<300).contains(status) else {
                    if status == 401 {
                        completion(.failure(MonitorError.loginRequired(self.site.name)))
                    } else {
                        completion(.failure(MonitorError.http(status)))
                    }
                    return
                }
                guard let data = body.data(using: .utf8) else {
                    completion(.failure(MonitorError.invalidResponse("接口响应不是 UTF-8")))
                    return
                }
                do {
                    completion(.success(AuthenticatedAPIClient.unwrap(try JSONSerialization.jsonObject(with: data))))
                } catch {
                    completion(.failure(error))
                }
            }
        }
    }

    private func failPending(_ error: Error) {
        let requests = pending
        pending.removeAll()
        for (_, _, completion) in requests { completion(.failure(error)) }
    }
}

private let tokenCaptureScript = """
function normalizeToken(value) {
  if (!value) return null;
  let text = String(value).trim();
  try {
    const parsed = JSON.parse(text);
    if (typeof parsed === 'string') text = parsed.trim();
    else if (parsed && typeof parsed === 'object') {
      text = String(parsed.access_token || parsed.accessToken || parsed.token || parsed.value || '').trim();
    }
  } catch (_) {}
  return text.replace(/^Bearer\\s+/i, '').trim() || null;
}
function readStorage(keys) {
  for (const key of keys) {
    try {
      const local = localStorage.getItem(key);
      if (local) return local;
    } catch (_) {}
    try {
      const session = sessionStorage.getItem(key);
      if (session) return session;
    } catch (_) {}
  }
  return null;
}
JSON.stringify({
  accessToken: normalizeToken(readStorage(['auth_token', 'access_token', 'accessToken', 'token'])),
  refreshToken: normalizeToken(readStorage(['refresh_token', 'refreshToken'])),
  expiresAt: readStorage(['token_expires_at', 'expires_at', 'expiresAt'])
})
"""

private func decodedToken(from result: Any?) -> TokenRecord? {
    guard let json = result as? String,
          let data = json.data(using: .utf8),
          let values = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let access = values["accessToken"] as? String, !access.isEmpty else { return nil }
    let expiresAt: Double?
    if let value = values["expiresAt"] as? String,
       let timestamp = Double(value) {
        expiresAt = timestamp > 10_000_000_000 ? timestamp / 1000 : timestamp
    } else {
        expiresAt = nil
    }
    return TokenRecord(
        accessToken: access,
        refreshToken: values["refreshToken"] as? String,
        expiresAt: expiresAt
    )
}

private final class LoginWindowController: NSObject, WKNavigationDelegate, NSWindowDelegate {
    private let site: SiteConfig
    private let tokenStore: TokenStore
    private let webView: WKWebView
    private let window: NSWindow
    private var timer: Timer?
    var onLogin: (() -> Void)?
    var onClose: (() -> Void)?

    init(site: SiteConfig, tokenStore: TokenStore) {
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
        webView.evaluateJavaScript(tokenCaptureScript) { [weak self] result, _ in
            guard let self, let token = decodedToken(from: result) else { return }
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

private final class WebSessionRestorer: NSObject, WKNavigationDelegate {
    private let site: SiteConfig
    private let tokenStore: TokenStore
    private let webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
    private var timer: Timer?
    private var attempts = 0
    private let completion: (Bool) -> Void

    init(site: SiteConfig, tokenStore: TokenStore, completion: @escaping (Bool) -> Void) {
        self.site = site
        self.tokenStore = tokenStore
        self.completion = completion
        super.init()
        webView.navigationDelegate = self
    }

    func start() {
        guard let url = URL(string: site.base_url + site.login_path) else {
            finish(false)
            return
        }
        webView.load(URLRequest(url: url))
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.captureToken()
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        captureToken()
    }

    private func captureToken() {
        attempts += 1
        webView.evaluateJavaScript(tokenCaptureScript) { [weak self] result, _ in
            guard let self else { return }
            if let token = decodedToken(from: result),
               (try? self.tokenStore.save(token, site: self.site.name)) != nil {
                self.finish(true)
            } else if self.attempts >= 20 {
                self.finish(false)
            }
        }
    }

    private func finish(_ restored: Bool) {
        guard timer != nil || attempts == 0 else { return }
        timer?.invalidate()
        timer = nil
        webView.stopLoading()
        completion(restored)
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

private struct CacheRateSnapshot {
    let requestCount: Int
    let inputTokens: Double
    let cacheCreationTokens: Double
    let cacheReadTokens: Double

    var totalCacheableTokens: Double {
        inputTokens + cacheCreationTokens + cacheReadTokens
    }

    var hitRate: Double? {
        guard totalCacheableTokens > 0 else { return nil }
        return cacheReadTokens / totalCacheableTokens * 100
    }
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
    let cacheRate: CacheRateSnapshot?
    let cacheWindowMinutes: Double
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

private func formatCacheWindow(_ minutes: Double) -> String {
    if minutes >= 60, (minutes / 60).rounded() == minutes / 60 {
        return "\(Int(minutes / 60))小时"
    }
    return minutes.rounded() == minutes ? "\(Int(minutes))分钟" : String(format: "%.1f分钟", minutes)
}

private func formatTokenCount(_ value: Double) -> String {
    let absolute = abs(value)
    if absolute >= 1_000_000 {
        return String(format: "%.1fM", value / 1_000_000)
    }
    if absolute >= 1_000 {
        return String(format: "%.1fk", value / 1_000)
    }
    return String(format: "%.0f", value)
}

private func formatCacheRate(_ snapshot: CacheRateSnapshot?, windowMinutes: Double, includeWindowWhenEmpty: Bool) -> String {
    guard let snapshot else {
        return includeWindowWhenEmpty ? "缓存 -- · 近\(formatCacheWindow(windowMinutes))无数据" : "缓存 --"
    }
    let rate = snapshot.hitRate.map { String(format: "%.1f%%", $0) } ?? "--"
    return "缓存 \(rate) · \(formatTokenCount(snapshot.cacheReadTokens))/\(formatTokenCount(snapshot.totalCacheableTokens)) · \(snapshot.requestCount)次"
}

private class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

private final class AccountRowView: FlippedView {
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let metricLabel = NSTextField(labelWithString: "")
    private let cacheLabel = NSTextField(labelWithString: "")
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
        cacheLabel.font = .systemFont(ofSize: 12)
        cacheLabel.textColor = .secondaryLabelColor
        cacheLabel.lineBreakMode = .byTruncatingTail
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
        [titleLabel, detailLabel, metricLabel, cacheLabel, scheduleToggle, monitorButton, skipButton, separator].forEach(addSubview)
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        let rightWidth: CGFloat = 108
        let textWidth = max(120, bounds.width - rightWidth - 18)
        titleLabel.frame = NSRect(x: 8, y: 7, width: textWidth, height: 18)
        detailLabel.frame = NSRect(x: 8, y: 27, width: textWidth, height: 16)
        metricLabel.frame = NSRect(x: 8, y: 47, width: bounds.width - 16, height: 16)
        cacheLabel.frame = NSRect(x: 8, y: 65, width: bounds.width - 16, height: 16)
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
        cacheLabel.stringValue = formatCacheRate(entry.cacheRate, windowMinutes: entry.cacheWindowMinutes, includeWindowWhenEmpty: true)

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
    private let cacheTitle = NSTextField(labelWithString: "缓存命中率")
    private let cacheValue = NSTextField(labelWithString: "整体 --")
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
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 685))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        contentScroll.frame = NSRect(x: 0, y: 38, width: 360, height: 647)
        contentScroll.autoresizingMask = [.width, .height]
        contentScroll.hasVerticalScroller = true
        contentScroll.autohidesScrollers = true
        contentScroll.borderType = .noBorder
        contentScroll.drawsBackground = false
        contentScroll.documentView = contentDocument
        contentDocument.frame = NSRect(x: 0, y: 0, width: 360, height: 450)
        overviewView.frame = NSRect(x: 0, y: 0, width: 360, height: 415)
        accountListView.frame = NSRect(x: 10, y: 415, width: 340, height: 35)
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

        cacheTitle.font = .systemFont(ofSize: 13, weight: .medium)
        cacheValue.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        cacheValue.textColor = .secondaryLabelColor
        cacheValue.maximumNumberOfLines = 2
        cacheValue.lineBreakMode = .byTruncatingTail
        let cacheBox = boxView()
        addViews([cacheTitle, cacheValue], to: cacheBox)
        cacheTitle.frame = NSRect(x: 14, y: 40, width: 300, height: 20)
        cacheValue.frame = NSRect(x: 14, y: 6, width: 312, height: 31)

        latencyBox.frame = NSRect(x: 10, y: 286, width: 340, height: 129)
        statusBox.frame = NSRect(x: 10, y: 179, width: 340, height: 97)
        recentBox.frame = NSRect(x: 10, y: 106, width: 340, height: 63)
        cacheBox.frame = NSRect(x: 10, y: 33, width: 340, height: 63)
        overviewView.addSubview(latencyBox)
        overviewView.addSubview(statusBox)
        overviewView.addSubview(recentBox)
        overviewView.addSubview(cacheBox)

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

    func update(usage: UsageSnapshot?, account: AccountSnapshot?, balance: Double?, channel: ChannelSnapshot?, externalKey: ExternalKeySnapshot?, recent: [Double], cacheRate: CacheRateSnapshot?, cacheWindowMinutes: Double, accounts: [AccountListEntry], updatedAt: Date?, error: String?) {
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
        cacheTitle.stringValue = "缓存命中率 · 最近 \(formatCacheWindow(cacheWindowMinutes))"
        if let cacheRate {
            let rate = cacheRate.hitRate.map { String(format: "整体 %.1f%%", $0) } ?? "整体 --"
            cacheValue.stringValue = "\(rate)\n\(formatTokenCount(cacheRate.cacheReadTokens))/\(formatTokenCount(cacheRate.totalCacheableTokens)) tokens · \(cacheRate.requestCount) 次请求"
        } else {
            cacheValue.stringValue = "整体 --\n最近 \(formatCacheWindow(cacheWindowMinutes))无数据"
        }
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
        let rowHeight: CGFloat = 86
        let previousOrigin = contentScroll.contentView.bounds.origin
        accountRows.forEach { $0.removeFromSuperview() }
        accountRows.removeAll()
        let listHeight = 32 + CGFloat(entries.count) * rowHeight
        accountListView.frame = NSRect(x: 10, y: 415, width: 340, height: listHeight)
        contentDocument.frame = NSRect(x: 0, y: 0, width: 360, height: 415 + listHeight + 10)
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
    private let tokenStore = TokenStore()
    private var config: AIConfig?
    private var subClient: AuthenticatedAPIClient?
    private var webClients: [String: WebKitAPIClient] = [:]
    private var timers: [Timer] = []
    private var clickMonitor: Any?
    private var loginWindows: [String: LoginWindowController] = [:]
    private var webSessionRestorers: [String: WebSessionRestorer] = [:]
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
    private var overallCacheRate: CacheRateSnapshot?
    private var cacheRatesByAccountID: [Int: CacheRateSnapshot] = [:]
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
        popover.contentSize = NSSize(width: 360, height: 685)
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
            subClient = AuthenticatedAPIClient(site: loaded.sub2api, timeout: loaded.httpTimeout, tokens: tokenStore)
            for upstream in loaded.upstreamOverrides {
                let client = WebKitAPIClient(site: upstream.site, timeout: loaded.httpTimeout)
                webClients[upstream.site.name] = client
                client.start()
            }
            scheduleTimers(loaded)
            refreshAll()
            restoreExistingWebSessions(config: loaded)
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
            URLQueryItem(name: "page_size", value: "200"),
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
                    let matchingItems = self.items(from: object).filter { self.matchesUsage($0, config: config) }
                    self.updateCacheRates(from: matchingItems, windowMinutes: config.cacheWindowMinutes)
                    guard let item = matchingItems.first else {
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

    private func updateCacheRates(from items: [[String: Any]], windowMinutes: Double) {
        let cutoff = Date().addingTimeInterval(-windowMinutes * 60)
        var overall = (requestCount: 0, input: 0.0, creation: 0.0, read: 0.0)
        var byAccount: [Int: (requestCount: Int, input: Double, creation: Double, read: Double)] = [:]

        for item in items {
            guard let createdAt = string(item, keys: ["created_at", "time"]),
                  let date = parseTimestamp(createdAt), date >= cutoff else { continue }
            let input = number(item, keys: ["input_tokens", "prompt_tokens", "uncached_input_tokens"]) ?? 0
            let creation = number(item, keys: ["cache_creation_tokens", "cache_creation_input_tokens", "cache_write_tokens"]) ?? 0
            let read = number(item, keys: ["cache_read_tokens", "cache_read_input_tokens", "cached_tokens"]) ?? 0
            overall.requestCount += 1
            overall.input += input
            overall.creation += creation
            overall.read += read
            if let accountID = usageAccountID(from: item) {
                var aggregate = byAccount[accountID] ?? (requestCount: 0, input: 0, creation: 0, read: 0)
                aggregate.requestCount += 1
                aggregate.input += input
                aggregate.creation += creation
                aggregate.read += read
                byAccount[accountID] = aggregate
            }
        }

        overallCacheRate = overall.requestCount > 0
            ? CacheRateSnapshot(requestCount: overall.requestCount, inputTokens: overall.input, cacheCreationTokens: overall.creation, cacheReadTokens: overall.read)
            : nil
        cacheRatesByAccountID = byAccount.mapValues {
            CacheRateSnapshot(requestCount: $0.requestCount, inputTokens: $0.input, cacheCreationTokens: $0.creation, cacheReadTokens: $0.read)
        }
    }

    private func usageAccountID(from item: [String: Any]) -> Int? {
        number(item, keys: ["account_id"]).map(Int.init)
            ?? (item["account"] as? [String: Any]).flatMap { number($0, keys: ["id"]) }.map(Int.init)
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
        let client: APIClient = webClients[upstream.site.name]
            ?? AuthenticatedAPIClient(site: upstream.site, timeout: config.httpTimeout, tokens: tokenStore)
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
            let cacheMetric = overallCacheRate?.hitRate.map { String(format: " %.1f%%", $0) } ?? " --"
            statusItem.button?.title = latency + cacheMetric + accountMetric + multiplier
            let cacheWindow = formatCacheWindow(config?.cacheWindowMinutes ?? 180)
            statusItem.button?.toolTip = "\(usage.account) · \(usage.model) · 首字延迟 \(Int(usage.firstTokenMs))ms · 最近 \(cacheWindow)缓存命中率 \(overallCacheRate?.hitRate.map { String(format: "%.1f%%", $0) } ?? "--")\(accountMetric)\(multiplier)"
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
                cacheRate: cacheRatesByAccountID[account.id],
                cacheWindowMinutes: config?.cacheWindowMinutes ?? 180,
                isScheduleUpdating: scheduleUpdatesInFlight.contains(account.id)
            )
        }
        dashboard.update(usage: usage, account: account, balance: balance, channel: channel, externalKey: externalKey, recent: recentTTFT, cacheRate: overallCacheRate, cacheWindowMinutes: config?.cacheWindowMinutes ?? 180, accounts: entries, updatedAt: updatedAt, error: lastError)
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

    private func restoreExistingWebSessions(config: AIConfig) {
        let sites = [config.sub2api] + config.upstreamOverrides.map(\.site)
        let missing = sites.filter { tokenStore.load(site: $0.name) == nil }
        guard !missing.isEmpty else { return }
        var remaining = missing.count
        var restoredAny = false
        for site in missing {
            let restorer = WebSessionRestorer(site: site, tokenStore: tokenStore) { [weak self] restored in
                guard let self else { return }
                self.webSessionRestorers.removeValue(forKey: site.name)
                restoredAny = restoredAny || restored
                remaining -= 1
                if remaining == 0 {
                    if restoredAny {
                        self.refreshAll()
                        self.refreshAccountMonitors()
                    }
                    self.showFirstMissingLogin()
                }
            }
            webSessionRestorers[site.name] = restorer
            restorer.start()
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
