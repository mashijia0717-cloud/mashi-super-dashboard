import AppKit
import Security
import WebKit

enum MagpieServerPage: Int, CaseIterable {
    case routing, usage

    var title: String { self == .routing ? "模型路由" : "用量概览" }

    func url(at server: URL) -> URL {
        var parts = URLComponents(url: server, resolvingAgainstBaseURL: false)!
        parts.queryItems = [URLQueryItem(name: "view", value: self == .routing ? "routing" : "usage")]
        if self == .usage { parts.queryItems?.append(URLQueryItem(name: "tab", value: "usage")) }
        return parts.url!
    }
}

/// A server website login, separate from model API keys. Never part of a URL,
/// source resource, UserDefaults, or JavaScript; WebKit gets an HttpOnly cookie.
struct MagpieServerConnection: Codable {
    let serverURL: String
    let webKey: String
    static let service = "com.local.CPAQuotaBar.magpie-server"
    static let account = "website"

    var url: URL? {
        guard let p = URLComponents(string: serverURL),
              ["http", "https"].contains(p.scheme?.lowercased() ?? ""),
              let host = p.host?.lowercased(), !host.isEmpty,
              !["localhost", "127.0.0.1", "::1", "[::1]", "0.0.0.0"].contains(host),
              p.user == nil, p.password == nil, p.query == nil, p.fragment == nil,
              p.path.isEmpty || p.path == "/" else { return nil }
        return p.url
    }

    var isValid: Bool {
        url != nil && webKey.count >= 16 && webKey.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
                || [45, 46, 95, 126].contains($0)
        }
    }

    func allows(_ target: URL) -> Bool {
        guard let base = url else { return false }
        func port(_ u: URL) -> Int { u.port ?? (u.scheme == "https" ? 443 : 80) }
        return target.scheme == base.scheme && target.host == base.host && port(target) == port(base)
    }

    var cookie: HTTPCookie? {
        guard let url, let host = url.host else { return nil }
        // The website's internal listening port names its auth cookie, even
        // when nginx serves it on 80. This is the existing server deployment.
        var properties: [HTTPCookiePropertyKey: Any] = [
            .name: "magpie_web_3430", .value: webKey, .domain: host, .path: "/",
            HTTPCookiePropertyKey("HttpOnly"): "TRUE"
        ]
        if url.scheme == "https" { properties[.secure] = "TRUE" }
        return HTTPCookie(properties: properties)
    }

    static func load() -> MagpieServerConnection? {
        var result: CFTypeRef?
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: account,
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let saved = try? JSONDecoder().decode(Self.self, from: data), saved.isValid else { return nil }
        return saved
    }

    func save() throws {
        guard isValid else { throw ConnectionError.invalid }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service, kSecAttrAccount as String: Self.account]
        let values: [String: Any] = [kSecValueData as String: try JSONEncoder().encode(self)]
        var status = SecItemUpdate(query as CFDictionary, values as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(values) { _, new in new } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw ConnectionError.keychain(status) }
    }

    enum ConnectionError: LocalizedError {
        case invalid, keychain(OSStatus)
        var errorDescription: String? {
            switch self {
            case .invalid: return "请填写服务器网站根地址和现有的网页登录密钥。不能使用本机地址。"
            case .keychain(let code): return "无法保存到系统钥匙串（\(code)）。"
            }
        }
    }
}

@MainActor
final class MagpieDashboardController: NSViewController, WKNavigationDelegate {
    private let status = NSTextField(labelWithString: "服务器数据")
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private let webHost = NSView()
    private var webView: WKWebView?
    private var connection: MagpieServerConnection?
    private var page: MagpieServerPage = .routing
    private var hasLoaded = false
    private var loadTask: Task<Void, Never>?
    private var releaseWebViewTask: Task<Void, Never>?

    init() {
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func ensureWebView() -> WKWebView {
        releaseWebViewTask?.cancel()
        releaseWebViewTask = nil
        if let existing = webView { return existing }
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        // Retain the original server views. Only remove their outer navigation;
        // the dashboard's native tabs replace it. All API calls remain remote.
        let script = """
        try { localStorage.setItem('magpie.navLayout', 'top'); } catch (_) {}
        document.addEventListener('DOMContentLoaded', () => {
          const style = document.createElement('style');
          style.textContent = '#side,header.top,#ptabs{display:none!important}body,body.side-nav{padding:0!important;--side-w:0px!important}.view{padding:18px!important}';
          document.head.append(style);
        });
        """
        config.userContentController.addUserScript(WKUserScript(source: script,
            injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let created = WKWebView(frame: .zero, configuration: config)
        created.navigationDelegate = self
        created.setAccessibilityLabel("服务器 Magpie 页面")
        created.translatesAutoresizingMaskIntoConstraints = false
        webHost.addSubview(created)
        NSLayoutConstraint.activate([
            created.topAnchor.constraint(equalTo: webHost.topAnchor),
            created.leadingAnchor.constraint(equalTo: webHost.leadingAnchor),
            created.trailingAnchor.constraint(equalTo: webHost.trailingAnchor),
            created.bottomAnchor.constraint(equalTo: webHost.bottomAnchor)
        ])
        webView = created
        return created
    }

    private func destroyWebView() {
        guard let existing = webView else { return }
        existing.stopLoading()
        existing.navigationDelegate = nil
        existing.removeFromSuperview()
        webView = nil
        hasLoaded = false
    }

    override func loadView() {
        let content = NSView()
        view = content
        let reload = NSButton(title: "刷新", target: self, action: #selector(reloadPage))
        reload.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: nil)
        let settings = NSButton(title: "连接设置", target: self, action: #selector(configureConnection))
        let spacer = NSView()
        let toolbar = NSStackView(views: [status, spacer, reload, settings])
        toolbar.orientation = .horizontal
        toolbar.spacing = 12
        toolbar.edgeInsets = NSEdgeInsets(top: 12, left: 18, bottom: 12, right: 18)
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingMiddle
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        errorLabel.alignment = .center
        errorLabel.textColor = .secondaryLabelColor
        errorLabel.font = .systemFont(ofSize: 15)
        errorLabel.isHidden = true
        for child in [toolbar, webHost, errorLabel] {
            child.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(child)
        }
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: content.topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: 54),
            webHost.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            webHost.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            webHost.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            webHost.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            errorLabel.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            errorLabel.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            errorLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 540)
        ])
    }

    func show(page: MagpieServerPage) {
        releaseWebViewTask?.cancel()
        releaseWebViewTask = nil
        let changed = self.page != page
        self.page = page
        loadViewIfNeeded()
        if !hasLoaded || changed { loadPage() }
    }

    func suspend() {
        guard hasLoaded || loadTask != nil || webView != nil else { return }
        loadTask?.cancel()
        loadTask = nil
        hasLoaded = false
        webView?.stopLoading()
        webView?.loadHTMLString("", baseURL: nil)
        releaseWebViewTask?.cancel()
        releaseWebViewTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard !Task.isCancelled, let self, !self.hasLoaded else { return }
            self.destroyWebView()
        }
    }

    @objc private func reloadPage() { loadPage() }

    private func loadPage() {
        loadTask?.cancel()
        connection = MagpieServerConnection.load()
        guard let connection, let url = connection.url, let cookie = connection.cookie else {
            showError("尚未连接服务器。请点右上角“连接设置”，使用服务器现有的网页登录密钥。")
            return
        }
        status.stringValue = "正在连接服务器 · \(url.host ?? "")"
        status.toolTip = url.absoluteString
        errorLabel.isHidden = true
        webHost.isHidden = false
        let activeWebView = ensureWebView()
        hasLoaded = true
        let destination = page.url(at: url)
        loadTask = Task { [weak self] in
            guard self != nil else { return }
            await activeWebView.configuration.websiteDataStore.httpCookieStore.setCookie(cookie)
            guard !Task.isCancelled else { return }
            activeWebView.load(URLRequest(url: destination, cachePolicy: .useProtocolCachePolicy, timeoutInterval: 25))
        }
    }

    private func showError(_ message: String) {
        hasLoaded = false
        status.stringValue = "服务器未连接"
        errorLabel.stringValue = message
        errorLabel.isHidden = false
        webHost.isHidden = true
    }

    @objc private func configureConnection() {
        guard let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = "连接服务器 Magpie"
        alert.informativeText = "填写网站地址和现有的网页登录密钥。登录保存在系统钥匙串；页面只读取这台服务器的数据。"
        alert.addButton(withTitle: "保存并连接")
        alert.addButton(withTitle: "取消")
        let address = NSTextField(string: connection?.serverURL ?? "")
        address.placeholderString = "https://magpie.example.com"
        let key = NSSecureTextField(string: connection?.webKey ?? "")
        let form = NSStackView(views: [NSTextField(labelWithString: "服务器网站地址"), address,
            NSTextField(labelWithString: "现有网页登录密钥"), key])
        form.orientation = .vertical
        form.alignment = .width
        form.spacing = 8
        form.setFrameSize(NSSize(width: 390, height: 112))
        address.setAccessibilityLabel("服务器网站地址")
        key.setAccessibilityLabel("现有网页登录密钥")
        alert.accessoryView = form
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            do {
                let config = MagpieServerConnection(serverURL: address.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
                    webKey: key.stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
                try config.save()
                loadPage()
            } catch { showError(error.localizedDescription) }
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let url = action.request.url else { return .cancel }
        if connection?.allows(url) == true || url.absoluteString == "about:blank" {
            return .allow
        } else {
            if action.navigationType == .linkActivated && ["http", "https"].contains(url.scheme ?? "") {
                NSWorkspace.shared.open(url)
            }
            return .cancel
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        if response.isForMainFrame, let http = response.response as? HTTPURLResponse, http.statusCode >= 400 {
            showError(http.statusCode == 401 || http.statusCode == 403
                ? "服务器登录已失效。请在“连接设置”中更新现有的网页登录密钥。"
                : "服务器返回错误 \(http.statusCode)。请稍后点“刷新”。")
            return .cancel
        } else { return .allow }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard hasLoaded, connection?.allows(webView.url ?? URL(string: "about:blank")!) == true else { return }
        status.stringValue = "服务器 · \(connection?.url?.host ?? "")"
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if (error as NSError).code != NSURLErrorCancelled {
            showError("无法连接服务器：\(error.localizedDescription)\n请检查网络后点“刷新”。")
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        self.webView(webView, didFailProvisionalNavigation: navigation, withError: error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        showError("页面进程已停止。点“刷新”可重新连接服务器。")
    }

}
