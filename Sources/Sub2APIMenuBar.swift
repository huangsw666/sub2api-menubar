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
        guard let token = tokens.load(site: site.name) else {
            completion(.failure(MonitorError.loginRequired(site.name)))
            return
        }
        perform(path: path, query: query, token: token, retryAfterRefresh: true, completion: completion)
    }

    private func perform(
        path: String,
        query: [URLQueryItem],
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
        request.timeoutInterval = timeout
        request.setValue("Bearer \(token.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
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
                        self?.perform(path: path, query: query, token: refreshed, retryAfterRefresh: false, completion: completion)
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
    let remaining5h: Double?
    let remaining7d: Double?

    var isSubscription: Bool { type.lowercased() == "oauth" }
    var minimumRemaining: Double? {
        let values = [remaining5h, remaining7d].compactMap { $0 }
        return values.min()
    }
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

private final class AIDashboardViewController: NSViewController {
    private let ttftValue = NSTextField(labelWithString: "--")
    private let usageDetail = NSTextField(labelWithString: "等待 Sub2API 登录")
    private let accountMetricTitle = NSTextField(labelWithString: "上游余额")
    private let balanceValue = NSTextField(labelWithString: "--")
    private let channelTitle = NSTextField(labelWithString: "渠道")
    private let channelValue = NSTextField(labelWithString: "等待上游数据")
    private let updateValue = NSTextField(labelWithString: "尚未更新")
    private let recentStack = NSStackView()
    var onRefresh: (() -> Void)?
    var onLoginSub2API: (() -> Void)?
    var onLoginUpstream: (() -> Void)?
    var onOpenUsage: (() -> Void)?
    var onQuit: (() -> Void)?

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 360))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        let title = NSTextField(labelWithString: "AI 延迟")
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        ttftValue.font = .monospacedDigitSystemFont(ofSize: 32, weight: .semibold)
        ttftValue.textColor = .systemBlue
        usageDetail.font = .systemFont(ofSize: 11)
        usageDetail.textColor = .secondaryLabelColor
        usageDetail.maximumNumberOfLines = 2

        let latencyBox = boxView()
        addViews([title, ttftValue, usageDetail], to: latencyBox)
        title.frame = NSRect(x: 12, y: 102, width: 120, height: 20)
        ttftValue.frame = NSRect(x: 12, y: 55, width: 250, height: 42)
        usageDetail.frame = NSRect(x: 12, y: 12, width: 252, height: 36)

        accountMetricTitle.font = .systemFont(ofSize: 12, weight: .medium)
        balanceValue.font = .monospacedDigitSystemFont(ofSize: 20, weight: .semibold)
        balanceValue.maximumNumberOfLines = 2
        balanceValue.lineBreakMode = .byWordWrapping
        balanceValue.cell?.wraps = true
        balanceValue.cell?.usesSingleLineMode = false
        channelTitle.font = .systemFont(ofSize: 12, weight: .medium)
        channelValue.font = .systemFont(ofSize: 11)
        channelValue.maximumNumberOfLines = 3
        channelValue.textColor = .secondaryLabelColor
        let statusBox = boxView()
        addViews([accountMetricTitle, balanceValue, channelTitle, channelValue], to: statusBox)
        accountMetricTitle.frame = NSRect(x: 12, y: 76, width: 125, height: 18)
        balanceValue.frame = NSRect(x: 12, y: 19, width: 120, height: 50)
        channelTitle.frame = NSRect(x: 145, y: 76, width: 110, height: 18)
        channelValue.lineBreakMode = .byWordWrapping
        channelValue.cell?.wraps = true
        channelValue.cell?.usesSingleLineMode = false
        channelValue.frame = NSRect(x: 145, y: 11, width: 125, height: 62)

        let recentTitle = label("最近首字延迟", size: 12, weight: .medium)
        recentStack.orientation = .horizontal
        recentStack.distribution = .fillEqually
        recentStack.spacing = 4
        let recentBox = boxView()
        addViews([recentTitle, recentStack], to: recentBox)
        recentTitle.frame = NSRect(x: 12, y: 51, width: 120, height: 18)
        recentStack.frame = NSRect(x: 10, y: 11, width: 260, height: 30)
        setRecent([])

        latencyBox.frame = NSRect(x: 10, y: 210, width: 280, height: 134)
        statusBox.frame = NSRect(x: 10, y: 103, width: 280, height: 97)
        recentBox.frame = NSRect(x: 10, y: 31, width: 280, height: 62)
        container.addSubview(latencyBox)
        container.addSubview(statusBox)
        container.addSubview(recentBox)

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
            button.frame = NSRect(x: 10 + CGFloat(index) * 32, y: 2, width: 28, height: 26)
            button.isBordered = false
            button.toolTip = action.1
            container.addSubview(button)
        }
        updateValue.frame = NSRect(x: 172, y: 7, width: 118, height: 16)
        updateValue.alignment = .right
        updateValue.font = .systemFont(ofSize: 9)
        updateValue.textColor = .tertiaryLabelColor
        container.addSubview(updateValue)
        view = container
    }

    func update(usage: UsageSnapshot?, account: AccountSnapshot?, balance: Double?, channel: ChannelSnapshot?, externalKey: ExternalKeySnapshot?, recent: [Double], updatedAt: Date?, error: String?) {
        if let usage {
            ttftValue.stringValue = formatDuration(usage.firstTokenMs)
            let total = usage.durationMs.map { " · 总 \(formatDuration($0))" } ?? ""
            usageDetail.stringValue = "\(usage.account) · \(usage.model) · \(usage.group)\n\(usage.createdAt)\(total)"
        }
        if let account, account.isSubscription {
            accountMetricTitle.stringValue = "\(account.name) 剩余额度"
            balanceValue.font = .monospacedDigitSystemFont(ofSize: 15, weight: .semibold)
            let remaining5h = account.remaining5h.map { String(format: "5h %.0f%%", $0) } ?? "5h --"
            let remaining7d = account.remaining7d.map { String(format: "7d %.0f%%", $0) } ?? "7d --"
            balanceValue.stringValue = "\(remaining5h)\n\(remaining7d)"
            channelTitle.stringValue = "订阅账户"
            let status = localizedStatus(account.status)
            channelValue.stringValue = "\(status)\nOAuth 订阅\n#\(account.id)"
        } else {
            accountMetricTitle.stringValue = "\(account?.name ?? "上游") 余额"
            balanceValue.font = .monospacedDigitSystemFont(ofSize: 20, weight: .semibold)
            balanceValue.stringValue = balance.map { String(format: "$%.2f", $0) } ?? "--"
            let group = externalKey?.group ?? "gpt"
            let multiplier = externalKey.map { " · \(formatRateMultiplier($0.rateMultiplier))" } ?? ""
            channelTitle.stringValue = group + multiplier
            updateExternalChannel(channel, externalKey: externalKey)
        }
        setRecent(recent)
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
            let text = index < shown.count ? formatDuration(shown[index]) : "--"
            let field = NSTextField(labelWithString: text)
            field.alignment = .center
            field.font = .monospacedDigitSystemFont(ofSize: 10, weight: .medium)
            field.wantsLayer = true
            field.layer?.cornerRadius = 4
            field.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
            recentStack.addArrangedSubview(field)
        }
    }

    private func formatDuration(_ milliseconds: Double) -> String {
        milliseconds >= 1000 ? String(format: "%.2fs", milliseconds / 1000) : "\(Int(milliseconds))ms"
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
    private var upstreamClient: AuthenticatedAPIClient?
    private var activeUpstream: UpstreamConfig?
    private var timers: [Timer] = []
    private var clickMonitor: Any?
    private var loginWindows: [String: LoginWindowController] = [:]
    private var usage: UsageSnapshot?
    private var account: AccountSnapshot?
    private var channel: ChannelSnapshot?
    private var externalKey: ExternalKeySnapshot?
    private var balance: Double?
    private var recentTTFT: [Double] = []
    private var updatedAt: Date?
    private var lastError: String?
    private var accountRequestInFlight = false
    private var accountUpdatedAt: Date?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusItem.button?.title = "AI --"
        statusItem.button?.toolTip = "AI 首字延迟"
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover)
        statusItem.button?.sendAction(on: [.leftMouseDown])
        popover.behavior = .transient
        popover.animates = false
        popover.contentSize = NSSize(width: 300, height: 360)
        popover.contentViewController = dashboard
        _ = dashboard.view
        dashboard.onRefresh = { [weak self] in self?.refreshAll() }
        dashboard.onLoginSub2API = { [weak self] in self?.showLogin(for: self?.config?.sub2api) }
        dashboard.onLoginUpstream = { [weak self] in self?.showLogin(for: self?.activeUpstream?.site) }
        dashboard.onOpenUsage = { [weak self] in self?.openUsage() }
        dashboard.onQuit = { NSApp.terminate(nil) }
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
            (config.channelInterval, { [weak self] in self?.refreshChannel() }),
            (config.balanceInterval, { [weak self] in self?.refreshBalance() }),
            (config.balanceInterval, { [weak self] in self?.refreshExternalKey() }),
        ]
        for (interval, action) in definitions {
            let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in action() }
            RunLoop.main.add(timer, forMode: .common)
            timers.append(timer)
        }
    }

    private func refreshAll() {
        refreshUsage()
        refreshChannel()
        refreshBalance()
        refreshExternalKey()
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

    private func refreshChannel() {
        guard usesExternalRelay, let upstream = activeUpstream, let upstreamClient,
              let channelGroup = externalKey?.group ?? upstream.channel_group else { return }
        upstreamClient.get(path: "/api/v1/channel-monitors") { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success(let object):
                    let items = self.items(from: object)
                    guard let item = items.first(where: {
                        let name = self.string($0, keys: ["name", "group_name", "group"])?.lowercased()
                        return name == channelGroup.lowercased()
                    }) else {
                        self.showError("找不到渠道 \(channelGroup)")
                        return
                    }
                    self.channel = ChannelSnapshot(
                        name: self.string(item, keys: ["name", "group_name"]) ?? channelGroup,
                        status: self.string(item, keys: ["status", "primary_status", "health_status"]) ?? "未知",
                        latencyMs: self.number(item, keys: ["latency_ms", "primary_latency_ms", "dialog_latency_ms"]),
                        pingMs: self.number(item, keys: ["primary_ping_latency_ms", "ping_latency_ms", "ping_ms", "endpoint_ping_ms", "endpoint_latency_ms"]),
                        availability: self.number(item, keys: ["availability_7d", "availability", "success_rate"])
                    )
                    self.markUpdated()
                case .failure(let error): self.showError(error.localizedDescription)
                }
            }
        }
    }

    private func refreshBalance() {
        guard usesExternalRelay else { return }
        upstreamClient?.get(path: "/api/v1/auth/me") { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success(let object):
                    guard let dictionary = object as? [String: Any],
                          let value = self.number(dictionary, keys: ["balance"]) else {
                        self.showError("余额响应无法解析")
                        return
                    }
                    self.balance = value
                    self.markUpdated()
                case .failure(let error): self.showError(error.localizedDescription)
                }
            }
        }
    }

    private func refreshExternalKey() {
        guard usesExternalRelay, let upstream = activeUpstream, let upstreamClient else { return }
        let keyName = upstream.key_name ?? usage?.account ?? upstream.name
        let query = [
            URLQueryItem(name: "page", value: "1"),
            URLQueryItem(name: "page_size", value: "100"),
        ]
        upstreamClient.get(path: "/api/v1/keys", query: query) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success(let object):
                    guard let item = self.items(from: object).first(where: {
                        let name = self.string($0, keys: ["name"])?.lowercased()
                        return name == keyName.lowercased()
                    }) else {
                        self.showError("找不到同名上游密钥 \(keyName)")
                        return
                    }
                    guard let group = item["group"] as? [String: Any],
                          let multiplier = self.number(group, keys: ["rate_multiplier"]) else {
                        self.showError("同名密钥缺少分组或倍率")
                        return
                    }
                    self.externalKey = ExternalKeySnapshot(
                        name: self.string(item, keys: ["name"]) ?? keyName,
                        group: self.string(group, keys: ["name"]) ?? upstream.channel_group ?? "--",
                        rateMultiplier: multiplier,
                        currentConcurrency: self.number(item, keys: ["current_concurrency"]).map(Int.init)
                    )
                    self.markUpdated()
                    self.refreshChannel()
                case .failure(let error): self.showError(error.localizedDescription)
                }
            }
        }
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

    private var usesExternalRelay: Bool {
        guard let account, !account.isSubscription else { return false }
        return activeUpstream?.matches(accountName: account.name) == true
    }

    private func configureUpstream(for accountName: String, accountItem: [String: Any]? = nil) {
        guard let config else { return }
        let override = config.upstreamOverrides.first { $0.matches(accountName: accountName) }
        let discovered = accountItem.flatMap { discoverUpstream(accountName: accountName, accountItem: $0) }
        let next = override ?? discovered
        guard next?.name != activeUpstream?.name || next?.base_url != activeUpstream?.base_url else { return }
        activeUpstream = next
        upstreamClient = next.map {
            AuthenticatedAPIClient(site: $0.site, timeout: config.httpTimeout, tokens: tokenStore)
        }
        balance = nil
        channel = nil
        externalKey = nil
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
        let isFresh = account?.id == id
            && accountUpdatedAt.map { Date().timeIntervalSince($0) < 30 } == true
        guard !isFresh, !accountRequestInFlight, let subClient else { return }
        accountRequestInFlight = true
        let query = [
            URLQueryItem(name: "page", value: "1"),
            URLQueryItem(name: "page_size", value: "100"),
        ]
        subClient.get(path: "/api/v1/admin/accounts", query: query) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.accountRequestInFlight = false
                switch result {
                case .success(let object):
                    guard let item = self.items(from: object).first(where: {
                        self.number($0, keys: ["id"]).map(Int.init) == id
                    }) else {
                        self.showError("找不到上游账户 #\(id)")
                        return
                    }
                    let extra = item["extra"] as? [String: Any] ?? [:]
                    let used5h = self.number(extra, keys: ["codex_5h_used_percent", "codex_secondary_used_percent"])
                    let used7d = self.number(extra, keys: ["codex_7d_used_percent", "codex_primary_used_percent"])
                    self.account = AccountSnapshot(
                        id: id,
                        name: self.string(item, keys: ["name"]) ?? "#\(id)",
                        type: self.string(item, keys: ["type"]) ?? "unknown",
                        status: self.string(item, keys: ["status"]) ?? "unknown",
                        remaining5h: used5h.map { max(0, min(100, 100 - $0)) },
                        remaining7d: used7d.map { max(0, min(100, 100 - $0)) }
                    )
                    self.accountUpdatedAt = Date()
                    if let accountName = self.account?.name {
                        self.configureUpstream(for: accountName, accountItem: item)
                    }
                    if self.account?.isSubscription == false {
                        guard let site = self.activeUpstream?.site else {
                            self.showError("账户缺少可用的 credentials.base_url")
                            return
                        }
                        if self.tokenStore.load(site: site.name) == nil {
                            self.showLogin(for: site)
                            self.markUpdated()
                            return
                        }
                        self.refreshBalance()
                        self.refreshExternalKey()
                    }
                    self.markUpdated()
                case .failure(let error): self.showError(error.localizedDescription)
                }
            }
        }
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
            statusItem.button?.toolTip = "\(usage.account) · \(usage.model) · 首字延迟 \(Int(usage.firstTokenMs))ms"
        } else {
            statusItem.button?.title = lastError == nil ? "AI --" : "AI !"
            statusItem.button?.toolTip = lastError ?? "等待 AI 延迟数据"
        }
        dashboard.update(usage: usage, account: account, balance: balance, channel: channel, externalKey: externalKey, recent: recentTTFT, updatedAt: updatedAt, error: lastError)
    }

    private func showLogin(for site: SiteConfig?) {
        guard let site else { return }
        popover.performClose(nil)
        if let existing = loginWindows[site.name] { existing.show(); return }
        let controller = LoginWindowController(site: site, tokenStore: tokenStore)
        controller.onLogin = { [weak self] in
            self?.refreshAll()
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
