import Foundation
import WebKit

/// 分享扩展持久会话：原生接口复用 Cookie，失败后再导航网页并使用同源 fetch。
/// 网页用于 Cloudflare 验证与登录，正常取数时由父级保持 WebView 隐藏。
@MainActor
final class ShareWebSession: NSObject, WKNavigationDelegate {
    let webView: WKWebView

    private static let cookieNames = ["_t", "_forum_session", "cf_clearance", "_rt"]
    private static let maxResponseBytes = 8 * 1024 * 1024

    private let host: String
    private let cookieStore: WKHTTPCookieStore
    private(set) var cookieEpoch = UUID()
    private var cookieTail: Task<Void, Never>?
    private var prepareToken: UUID?
    private var navigationToken: UUID?
    private var navigationGate: ShareWebGate<Void>?
    private var navigationTimeout: Task<Void, Never>?
    private var activeNavigation: WKNavigation?
    private var pendingRequests: [UUID: ShareWebGate<Any>] = [:]
    private var imageTail: Task<Void, Never>?

    init(host: String) {
        let normalized = host.lowercased()
        self.host = normalized

        let configuration = WKWebViewConfiguration()
        // 默认容器属于分享扩展自身；即使没有 App Group 也能持久保留挑战和登录产生的 Cookie。
        configuration.websiteDataStore = .default()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        let web = WKWebView(frame: .zero, configuration: configuration)
        self.webView = web
        self.cookieStore = WKWebsiteDataStore.default().httpCookieStore
        super.init()
        web.navigationDelegate = self
    }

    /// 播种只写 Cookie，不导航帖子网页。
    func seed(session: ShareSession?) async throws {
        try Task.checkCancellation()
        try await apply(session: session)
        try Task.checkCancellation()
    }

    func nativeSession(for url: URL) async throws -> ShareSession? {
        guard Self.isAllowedOriginURL(url, host: host) else { throw ForumShareError.invalidLink }
        try Task.checkCancellation()
        let cookies = await allCookies().filter { cookie in
            Self.cookieNames.contains(cookie.name) && Self.normalizedDomain(cookie.domain) == host &&
                !cookie.value.isEmpty && (cookie.expiresDate.map { $0 > Date() } ?? true) &&
                (url.path == cookie.path || url.path.hasPrefix(cookie.path.hasSuffix("/") ? cookie.path : cookie.path + "/"))
        }.sorted { $0.path.count > $1.path.count }
        var names = Set<String>()
        let selected = cookies.filter { names.insert($0.name).inserted }
        guard !selected.isEmpty else { return nil }
        let agent: String
        if let custom = webView.customUserAgent { agent = custom }
        else {
            agent = await withCheckedContinuation { continuation in
                webView.evaluateJavaScript("navigator.userAgent") { value, _ in
                    continuation.resume(returning: value as? String ?? "")
                }
            }
        }
        try Task.checkCancellation()
        guard Self.isValidUserAgent(agent) else { throw ForumShareError.network }
        return ShareSession(cookieHeader: selected.map { "\($0.name)=\($0.value)" }.joined(separator: "; "), userAgent: agent)
    }

    /// 原生响应的同站 Cookie 回写扩展容器，供后续补帖和浏览器回退使用。
    func receiveCookies(from response: HTTPURLResponse, epoch: UUID) async {
        guard epoch == cookieEpoch else { return }
        let previous = cookieTail
        let write = Task { @MainActor [weak self] in
            await previous?.value
            guard let self = self, epoch == self.cookieEpoch else { return }
            await self.storeCookies(from: response, epoch: epoch)
        }
        cookieTail = write
        await write.value
    }

    private func storeCookies(from response: HTTPURLResponse, epoch: UUID) async {
        guard let url = response.url, Self.isAllowedOriginURL(url, host: host) else { return }
        var headers: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            if let key = key as? String, let value = value as? String { headers[key] = value }
        }
        for cookie in HTTPCookie.cookies(withResponseHeaderFields: headers, for: url)
            where Self.cookieNames.contains(cookie.name) && Self.normalizedDomain(cookie.domain) == host {
            guard epoch == cookieEpoch else { return }
            if cookie.expiresDate.map({ $0 <= Date() }) == true {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    cookieStore.delete(cookie) { continuation.resume() }
                }
            } else {
                await setCookie(cookie)
            }
        }
    }

    /// 注入共享会话后导航到帖子地址，等待 didFinish；重复调用会先终止上一次等待。
    func prepare(url: URL, session: ShareSession?) async throws {
        let token = UUID()
        prepareToken = token
        defer {
            if prepareToken == token { prepareToken = nil }
        }
        cancelPendingNavigation()
        cancelPendingRequests(CancellationError())

        guard SharedTopicLink.supportedHosts.contains(host),
              Self.isAllowedAPIURL(url, host: host) else {
            throw ForumShareError.invalidLink
        }
        try ensurePrepareActive(token)
        try await apply(session: session)
        try ensurePrepareActive(token)

        navigationToken = token
        let gate = ShareWebGate<Void>()
        navigationGate = gate
        do {
            try await withTaskCancellationHandler(operation: {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    guard gate.bind(continuation) else { return }
                    let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData,
                                             timeoutInterval: 60)
                    guard let navigation = self.webView.load(request) else {
                        gate.finish(.failure(ForumShareError.network))
                        return
                    }
                    self.activeNavigation = navigation
                    self.navigationTimeout = Task { @MainActor [weak self] in
                        do { try await Task.sleep(nanoseconds: 60_000_000_000) }
                        catch { return }
                        guard let self = self, self.navigationToken == token else { return }
                        self.webView.stopLoading()
                        self.finishNavigation(token, result: .failure(ForumShareError.network))
                    }
                }
            }, onCancel: {
                gate.finish(.failure(CancellationError()))
            })
            try ensurePrepareActive(token)
        } catch {
            abortNavigation(token)
            throw error
        }
    }

    /// 只在当前页面仍是目标原站时，通过隔离世界里的同源 fetch 取 JSON。
    /// HTTP 状态原样交给调用方解析，只有传输/校验失败才转为 ForumShareError。
    func request(_ url: URL) async throws -> (Data, HTTPURLResponse) {
        try await fetch(url, binary: false)
    }

    func image(_ url: URL) async throws -> (Data, HTTPURLResponse) {
        let previous = imageTail
        // 图片逐张跨 JS 桥，限制长文多图同时解码的内存峰值。
        let transfer = Task { @MainActor in
            await previous?.value
            try Task.checkCancellation()
            return try await fetch(url, binary: true)
        }
        imageTail = Task { _ = try? await transfer.value }
        return try await withTaskCancellationHandler(operation: {
            try await transfer.value
        }, onCancel: { transfer.cancel() })
    }

    private func fetch(_ url: URL, binary: Bool) async throws -> (Data, HTTPURLResponse) {
        guard SharedTopicLink.supportedHosts.contains(host),
              (binary ? Self.isAllowedOriginURL(url, host: host) : Self.isAllowedAPIURL(url, host: host)) else {
            throw ForumShareError.invalidLink
        }
        guard let current = webView.url, Self.isAllowedOriginURL(current, host: host) else {
            throw ForumShareError.loginRequired
        }
        try Task.checkCancellation()

        let token = UUID()
        let gate = ShareWebGate<Any>()
        pendingRequests[token] = gate
        defer { pendingRequests.removeValue(forKey: token) }

        let arguments: [String: Any] = [
            "url": url.absoluteString,
            "expectedOrigin": "https://\(host)",
            "timeoutMilliseconds": 30000,
            "maxBytes": binary ? 16 * 1024 * 1024 : Self.maxResponseBytes,
            "binary": binary,
            "requestID": token.uuidString,
        ]
        let script = """
        const controller = new AbortController();
        const controllers = globalThis.fluxdoShareRequests ||= new Map();
        controllers.set(requestID, controller);
        const timer = setTimeout(() => controller.abort(), timeoutMilliseconds);
        try {
          if (location.origin !== expectedOrigin) {
            return { ok: false, reason: "origin" };
          }
          const response = await fetch(url, {
            method: "GET",
            headers: {
              "Accept": binary ? "image/*" : "application/json",
              "X-Requested-With": "XMLHttpRequest"
            },
            credentials: "same-origin",
            redirect: "manual",
            cache: "no-store",
            signal: controller.signal
          });
          if (response.type === "opaqueredirect") {
            return { ok: false, reason: "redirect" };
          }
          let body = "";
          let total = 0;
          if (response.body) {
            const reader = response.body.getReader();
            const chunks = [];
            while (true) {
              const part = await reader.read();
              if (part.done) { break; }
              total += part.value.byteLength;
              if (total > maxBytes) {
                try { await reader.cancel(); } catch (_) {}
                return { ok: false, reason: "tooLarge" };
              }
              chunks.push(part.value);
            }
            const merged = new Uint8Array(total);
            let offset = 0;
            for (const chunk of chunks) {
              merged.set(chunk, offset);
              offset += chunk.byteLength;
            }
            if (binary) {
              let text = "";
              for (let start = 0; start < merged.length; start += 32768) {
                text += String.fromCharCode(...merged.subarray(start, start + 32768));
              }
              body = btoa(text);
            } else {
              body = new TextDecoder("utf-8").decode(merged);
            }
          } else {
            body = "";
          }
          return {
            ok: true,
            status: response.status,
            mitigated: response.headers.get("cf-mitigated") || "",
            contentType: response.headers.get("content-type") || "",
            body: body
          };
        } catch (error) {
          return { ok: false, reason: error && error.name === "AbortError" ? "timeout" : "network" };
        } finally {
          clearTimeout(timer);
          controllers.delete(requestID);
        }
        """
        let timeout = Task { @MainActor in
            do { try await Task.sleep(nanoseconds: 35_000_000_000) } catch { return }
            gate.finish(.failure(ForumShareError.network))
        }
        defer { timeout.cancel() }
        let result: Any
        do {
            result = try await withTaskCancellationHandler(operation: {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Any, Error>) in
                    guard gate.bind(continuation) else { return }
                    self.webView.callAsyncJavaScript(script, arguments: arguments, in: nil,
                                                     in: .defaultClient) { result in
                        gate.finish(result)
                    }
                }
            }, onCancel: {
                gate.finish(.failure(CancellationError()))
            })
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ForumShareError.network
        }
        try Task.checkCancellation()
        return try Self.parseResponse(result, url: url, binary: binary)
    }

    /// 终止当前导航和所有请求，但不删除持久 WebKit 数据；之后仍可再次 prepare。
    func cancel() {
        prepareToken = nil
        cancelPendingNavigation()
        cancelPendingRequests(CancellationError())
    }

    /// 清理扩展自己的默认 WebKit 容器和自定义 UA，不接触主应用共享文件或 App Group。
    func clear() async {
        cancel()
        cookieEpoch = UUID()
        await cookieTail?.value
        cookieTail = nil
        webView.customUserAgent = nil
        for host in SharedTopicLink.supportedHosts {
            UserDefaults.standard.removeObject(forKey: "ShareWebUserAgent." + host)
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            WKWebsiteDataStore.default().removeData(
                ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
                modifiedSince: .distantPast
            ) {
                continuation.resume()
            }
        }
    }

    private func ensurePrepareActive(_ token: UUID) throws {
        try Task.checkCancellation()
        guard prepareToken == token else { throw CancellationError() }
    }

    private func apply(session: ShareSession?) async throws {
        let savedAgent = UserDefaults.standard.string(forKey: "ShareWebUserAgent." + host)
        if let savedAgent = savedAgent, Self.isValidUserAgent(savedAgent) {
            webView.customUserAgent = savedAgent
        }
        let existing = await allCookies()
        let existingNames = Set(existing.filter {
            Self.cookieNames.contains($0.name) && Self.normalizedDomain($0.domain) == host &&
                !$0.value.isEmpty && ($0.expiresDate.map { $0 > Date() } ?? true)
        }.map { $0.name })
        // 扩展内已完成的验证优先保留；共享快照只补齐缺失的凭据。
        guard let session = session else { return }
        guard Self.isValidUserAgent(session.userAgent) else { throw ForumShareError.loginRequired }
        let values = Self.parseCookieHeader(session.cookieHeader)
        guard !values.isEmpty else { throw ForumShareError.loginRequired }
        if existingNames.isEmpty {
            webView.customUserAgent = session.userAgent
            UserDefaults.standard.set(session.userAgent, forKey: "ShareWebUserAgent." + host)
        }
        for name in Self.cookieNames {
            guard !existingNames.contains(name), let value = values[name] else { continue }
            try Task.checkCancellation()
            // 已有验证 Cookie 时保持其 UA，等待网页自行续签同一浏览器的验证状态。
            if name == "cf_clearance", !existingNames.isEmpty { continue }
            guard let cookie = Self.makeCookie(name: name, value: value, host: host) else {
                throw ForumShareError.loginRequired
            }
            await setCookie(cookie)
        }
    }

    private func allCookies() async -> [HTTPCookie] {
        await withCheckedContinuation { (continuation: CheckedContinuation<[HTTPCookie], Never>) in
            cookieStore.getAllCookies { cookies in
                continuation.resume(returning: cookies)
            }
        }
    }

    private func setCookie(_ cookie: HTTPCookie) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            cookieStore.setCookie(cookie) {
                continuation.resume()
            }
        }
    }

    private func cancelPendingNavigation() {
        navigationTimeout?.cancel()
        navigationTimeout = nil
        activeNavigation = nil
        navigationToken = nil
        let gate = navigationGate
        navigationGate = nil
        webView.stopLoading()
        gate?.finish(.failure(CancellationError()))
    }

    private func cancelPendingRequests(_ error: Error) {
        if !pendingRequests.isEmpty {
            webView.callAsyncJavaScript("globalThis.fluxdoShareRequests?.forEach(value => value.abort());",
                                        arguments: [:], in: nil, in: .defaultClient, completionHandler: nil)
        }
        let gates = Array(pendingRequests.values)
        pendingRequests.removeAll()
        for gate in gates {
            gate.finish(.failure(error))
        }
    }

    private func abortNavigation(_ token: UUID) {
        guard navigationToken == token else { return }
        cancelPendingNavigation()
    }

    private func finishNavigation(_ token: UUID, result: Result<Void, Error>) {
        guard navigationToken == token, let gate = navigationGate else { return }
        navigationTimeout?.cancel()
        navigationTimeout = nil
        activeNavigation = nil
        navigationToken = nil
        navigationGate = nil
        gate.finish(result)
    }

    private func failActiveNavigation(_ navigation: WKNavigation?) {
        guard let navigation = navigation,
              let active = activeNavigation,
              navigation === active,
              let token = navigationToken else { return }
        finishNavigation(token, result: .failure(ForumShareError.network))
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let navigation = navigation,
              let active = activeNavigation,
              navigation === active,
              let token = navigationToken else { return }
        finishNavigation(token, result: .success(Void()))
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        failActiveNavigation(navigation)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) {
        failActiveNavigation(navigation)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        if let token = navigationToken {
            finishNavigation(token, result: .failure(ForumShareError.network))
        }
        cancelPendingRequests(ForumShareError.network)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        // 登录可能跳到 connect 域，所以允许任意 HTTPS；新窗口、明文和自定义 scheme 一律取消。
        guard navigationAction.targetFrame != nil,
              let url = navigationAction.request.url,
              url.scheme?.lowercased() == "https",
              url.host != nil else {
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    private static func isAllowedOriginURL(_ url: URL, host: String) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https",
              components.host?.lowercased() == host,
              components.user == nil,
              components.password == nil,
              components.port == nil || components.port == 443 else {
            return false
        }
        return true
    }

    private static func isAllowedAPIURL(_ url: URL, host: String) -> Bool {
        guard isAllowedOriginURL(url, host: host),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return false
        }
        let path = components.percentEncodedPath
        return path.hasPrefix("/t/") || path.hasPrefix("/posts/")
    }

    private static func parseResponse(_ value: Any, url: URL, binary: Bool) throws -> (Data, HTTPURLResponse) {
        guard let object = value as? [String: Any],
              let ok = object["ok"] as? Bool else {
            throw ForumShareError.invalidResponse
        }
        guard ok else {
            switch (object["reason"] as? String) ?? "" {
            case "timeout", "network":
                throw ForumShareError.network
            case "tooLarge":
                throw ForumShareError.invalidResponse
            case "origin", "redirect":
                throw ForumShareError.loginRequired
            default:
                throw ForumShareError.network
            }
        }

        let status: Int
        if let number = object["status"] as? NSNumber {
            status = number.intValue
        } else if let number = object["status"] as? Int {
            status = number
        } else {
            throw ForumShareError.invalidResponse
        }
        guard (100...599).contains(status), let body = object["body"] as? String else {
            throw ForumShareError.invalidResponse
        }

        var headers: [String: String] = [:]
        if let mitigated = validHeaderValue(object["mitigated"] as? String) {
            headers["cf-mitigated"] = mitigated
        }
        if let contentType = validHeaderValue(object["contentType"] as? String) {
            headers["Content-Type"] = contentType
        }
        guard let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                             headerFields: headers) else {
            throw ForumShareError.invalidResponse
        }
        let data: Data
        if binary {
            guard let decoded = Data(base64Encoded: body), decoded.count <= 16 * 1024 * 1024 else {
                throw ForumShareError.invalidResponse
            }
            data = decoded
        } else {
            data = Data(body.utf8)
            guard data.count <= maxResponseBytes else { throw ForumShareError.invalidResponse }
        }
        return (data, response)
    }

    private static func validHeaderValue(_ value: String?) -> String? {
        guard let value = value, !value.isEmpty,
              !value.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else {
            return nil
        }
        return value
    }

    private static func isValidUserAgent(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 4096,
              !value.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else {
            return false
        }
        return true
    }

    private static func parseCookieHeader(_ header: String) -> [String: String] {
        var values: [String: String] = [:]
        for pair in header.split(separator: ";", omittingEmptySubsequences: true) {
            let item = pair.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let separator = item.firstIndex(of: "=") else { continue }
            let name = String(item[..<separator])
            let value = String(item[item.index(after: separator)...])
            guard cookieNames.contains(name), values[name] == nil,
                  isValidCookieValue(value) else { continue }
            values[name] = value
        }
        return values
    }

    private static func isValidCookieValue(_ value: String) -> Bool {
        guard !value.isEmpty else { return false }
        return value.unicodeScalars.allSatisfy {
            $0.value >= 33 && $0.value <= 126 && $0.value != 59
        }
    }

    private static func makeCookie(name: String, value: String, host: String) -> HTTPCookie? {
        // Foundation 没有公开的 HttpOnly 常量，沿用既有 Cookie 同步代码使用的原始属性键。
        let properties: [HTTPCookiePropertyKey: Any] = [
            .name: name,
            .value: value,
            .originURL: "https://\(host)/",
            .path: "/",
            .secure: "TRUE",
            HTTPCookiePropertyKey(rawValue: "HttpOnly"): "YES",
        ]
        guard let cookie = HTTPCookie(properties: properties),
              normalizedDomain(cookie.domain) == host, cookie.path == "/" else {
            return nil
        }
        return cookie
    }

    private static func normalizedDomain(_ domain: String) -> String {
        let lowercased = domain.lowercased()
        return lowercased.hasPrefix(".") ? String(lowercased.dropFirst()) : lowercased
    }
}

/// WebKit 回调不会自动响应 Swift Task 取消；门闩保证 continuation 只恢复一次，迟到回调直接丢弃。
private final class ShareWebGate<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var result: Result<Value, Error>?

    func bind(_ continuation: CheckedContinuation<Value, Error>) -> Bool {
        lock.lock()
        if let result = result {
            lock.unlock()
            continuation.resume(with: result)
            return false
        }
        self.continuation = continuation
        lock.unlock()
        return true
    }

    func finish(_ result: Result<Value, Error>) {
        lock.lock()
        guard self.result == nil else {
            lock.unlock()
            return
        }
        self.result = result
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}
