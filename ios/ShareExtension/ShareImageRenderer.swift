import UIKit
import WebKit

/// 使用隔离的 WebKit 容器逐页截图，不创建整篇文章大小的位图。
@MainActor
final class ShareImageRenderer: NSObject, WKNavigationDelegate {
    private var webView: WKWebView?
    private var imageProxy: ShareImageProxy?
    private var navigation: CheckedContinuation<Void, Error>?
    private var cancelled = false
    private var navigationTimeout: Task<Void, Never>?
    private var cancelPending: ((Error) -> Void)?

    func render(html: String, host: String, directory: URL, container: UIView,
                progress: @escaping (String) -> Void) async throws -> [URL] {
        cancelled = false
        let proxy = ShareImageProxy(host: host, session: ShareSessionStore.read(host: host))
        imageProxy = proxy
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.setURLSchemeHandler(proxy, forURLScheme: "fluxdo-share-image")
        let width = min(430, max(320, container.bounds.width))
        let pageHeight: CGFloat = 1000
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: width, height: pageHeight), configuration: configuration)
        web.isUserInteractionEnabled = false
        web.scrollView.isScrollEnabled = false
        web.scrollView.contentInsetAdjustmentBehavior = .never
        web.navigationDelegate = self
        web.backgroundColor = .white
        web.isOpaque = true
        container.insertSubview(web, at: 0)
        webView = web
        defer { cancel() }
        progress("正在排版并加载正文图片…")
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            navigation = continuation
            navigationTimeout = Task { [weak self] in
                do { try await Task.sleep(nanoseconds: 60_000_000_000) }
                catch { return }
                guard let self = self else { return }
                self.navigation?.resume(throwing: ShareImageError.message("正文排版加载超时，请重试。"))
                self.navigation = nil
                self.webView?.stopLoading()
            }
            web.loadHTMLString(html, baseURL: nil)
        }
        navigationTimeout?.cancel()
        navigationTimeout = nil
        try checkCancellation()
        // 这里只执行固定的可信脚本，正文脚本和所有页面导航均被禁用。
        let readiness = """
        const ready = async () => {
          await document.fonts.ready;
          const images = Array.from(document.images);
          await Promise.all(images.map(image => {
            image.loading = 'eager';
            return image.decode().catch(() => { throw new Error('正文图片加载失败，请重试'); });
          }));
          await new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)));
          if (Math.max(document.documentElement.scrollWidth, document.body.scrollWidth) > window.innerWidth + 1) {
            throw new Error('正文包含超宽内容，无法完整截图，请改用 HTML 导出');
          }
          return Math.ceil(Math.max(document.body.scrollHeight, document.body.getBoundingClientRect().bottom + window.scrollY));
        };
        return await Promise.race([ready(), new Promise((_, reject) => setTimeout(() => reject(new Error('图片或字体加载超时，请重试')), 45000))]);
        """
        let value = try await execute(readiness, in: web)
        try checkCancellation()
        guard let number = value as? NSNumber, number.doubleValue.isFinite, number.doubleValue > 0 else {
            throw ShareImageError.message("无法获取文章排版高度，请重试。")
        }
        let height = CGFloat(number.doubleValue)
        guard height <= pageHeight * 200 else {
            throw ShareImageError.message("文章过长，预计超过 200 张图片，未生成不完整结果。请改用 HTML 导出。")
        }
        let count = Int(ceil(height / pageHeight))
        var files: [URL] = []
        for index in 0..<count {
            try checkCancellation()
            progress("正在生成第 \(index + 1)/\(count) 张图片…")
            let start = CGFloat(index) * pageHeight
            let sliceHeight = min(pageHeight, height - start)
            let scrollOffset = min(start, max(0, height - pageHeight))
            web.scrollView.setContentOffset(CGPoint(x: 0, y: scrollOffset), animated: false)
            _ = try await execute("await new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve))); return true;", in: web)
            try checkCancellation()
            let actualOffset = web.scrollView.contentOffset.y
            let sliceOrigin = start - actualOffset
            guard sliceOrigin >= -0.5, sliceOrigin + sliceHeight <= pageHeight + 0.5 else {
                throw ShareImageError.message("正文分片位置无法完整呈现，未输出截断结果。请重试或使用 HTML 导出。")
            }
            let snapshot = WKSnapshotConfiguration()
            snapshot.rect = CGRect(x: 0, y: max(0, sliceOrigin), width: width, height: sliceHeight)
            snapshot.snapshotWidth = NSNumber(value: Double(width))
            snapshot.afterScreenUpdates = true
            let image = try await takeSnapshot(of: web, configuration: snapshot)
            try checkCancellation()
            let file = directory.appendingPathComponent(String(format: "FluxDO-%03d.png", index + 1))
            try autoreleasepool {
                guard let data = image.pngData() else {
                    throw ShareImageError.message("PNG 图片编码失败，请重试。")
                }
                try data.write(to: file, options: .atomic)
            }
            files.append(file)
        }
        return files
    }

    func cancel() {
        cancelled = true
        cancelPending?(CancellationError())
        cancelPending = nil
        navigationTimeout?.cancel()
        navigationTimeout = nil
        navigation?.resume(throwing: CancellationError())
        navigation = nil
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView?.removeFromSuperview()
        webView = nil
        imageProxy?.cancel()
        imageProxy = nil
    }

    private func checkCancellation() throws {
        try Task.checkCancellation()
        if cancelled { throw CancellationError() }
    }

    private func execute(_ script: String, in web: WKWebView) async throws -> Any? {
        defer {
            cancelPending = nil
            navigationTimeout?.cancel()
            navigationTimeout = nil
        }
        return try await withCheckedThrowingContinuation { continuation in
            let completion = ShareRenderCompletion<Any?>(continuation)
            cancelPending = { completion.finish(.failure($0)) }
            navigationTimeout = timeout(completion)
            web.callAsyncJavaScript(script, arguments: [:], in: nil, contentWorld: .defaultClient) { result in
                completion.finish(result.map { $0 as Any? })
            }
        }
    }

    private func takeSnapshot(of web: WKWebView, configuration: WKSnapshotConfiguration) async throws -> UIImage {
        defer {
            cancelPending = nil
            navigationTimeout?.cancel()
            navigationTimeout = nil
        }
        return try await withCheckedThrowingContinuation { continuation in
            let completion = ShareRenderCompletion<UIImage>(continuation)
            cancelPending = { completion.finish(.failure($0)) }
            navigationTimeout = timeout(completion)
            web.takeSnapshot(with: configuration) { image, error in
                if let error = error { completion.finish(.failure(error)) }
                else if let image = image { completion.finish(.success(image)) }
                else { completion.finish(.failure(ShareImageError.message("无法取得正文截图，请重试。"))) }
            }
        }
    }

    private func timeout<Value>(_ completion: ShareRenderCompletion<Value>) -> Task<Void, Never> {
        Task {
            do { try await Task.sleep(nanoseconds: 60_000_000_000) }
            catch { return }
            completion.finish(.failure(ShareImageError.message("正文图片渲染超时，请重试或导出 HTML。")))
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        self.navigation?.resume()
        self.navigation = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        self.navigation?.resume(throwing: error)
        self.navigation = nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        self.navigation?.resume(throwing: error)
        self.navigation = nil
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        cancelPending?(ShareImageError.message("图片排版进程已退出，请重试或导出 HTML。"))
        cancelPending = nil
        navigation?.resume(throwing: ShareImageError.message("图片排版进程已退出，请重试或导出 HTML。"))
        navigation = nil
        cancelled = true
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let isInitialDocument = navigationAction.navigationType == .other &&
            navigationAction.targetFrame?.isMainFrame == true &&
            navigationAction.request.url?.absoluteString == "about:blank"
        decisionHandler(isInitialDocument ? .allow : .cancel)
    }
}

private enum ShareImageError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let message): return message }
    }
}

/// 图片请求不进入 WebKit Cookie 存储；重定向每一跳重新限定 Cookie 的精确主机。
private final class ShareImageProxy: NSObject, WKURLSchemeHandler, URLSessionDataDelegate {
    private struct Transfer {
        let schemeTask: WKURLSchemeTask
        var bytes = 0
    }
    private let host: String
    private let authentication: ShareSession?
    private var transfers: [Int: Transfer] = [:]
    private var tasks: [ObjectIdentifier: URLSessionDataTask] = [:]
    private var session: URLSession!

    init(host: String, session authentication: ShareSession?) {
        self.host = host.lowercased()
        self.authentication = authentication
        super.init()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 45
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: .main)
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard var components = URLComponents(url: urlSchemeTask.request.url!, resolvingAgainstBaseURL: false),
              let imageHost = components.host, !imageHost.isEmpty,
              components.user == nil, components.password == nil,
              components.port == nil || components.port == 443 else {
            urlSchemeTask.didFailWithError(ShareImageError.message("文章图片地址不安全。"))
            return
        }
        components.scheme = "https"
        guard let url = components.url else {
            urlSchemeTask.didFailWithError(ShareImageError.message("文章图片地址无效。"))
            return
        }
        var request = URLRequest(url: url)
        request.httpShouldHandleCookies = false
        applyAuthentication(to: &request)
        let task = session.dataTask(with: request)
        transfers[task.taskIdentifier] = Transfer(schemeTask: urlSchemeTask)
        tasks[ObjectIdentifier(urlSchemeTask)] = task
        task.resume()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        guard let task = tasks.removeValue(forKey: ObjectIdentifier(urlSchemeTask)) else { return }
        transfers.removeValue(forKey: task.taskIdentifier)
        task.cancel()
    }

    func cancel() {
        transfers.removeAll()
        tasks.removeAll()
        session.invalidateAndCancel()
    }

    private func applyAuthentication(to request: inout URLRequest) {
        request.httpShouldHandleCookies = false
        request.setValue(nil, forHTTPHeaderField: "Cookie")
        request.setValue(nil, forHTTPHeaderField: "Authorization")
        request.setValue(nil, forHTTPHeaderField: "Referer")
        if ["linux.do", "idcflare.com"].contains(host), request.url?.host?.lowercased() == host {
            request.setValue(authentication?.cookieHeader, forHTTPHeaderField: "Cookie")
            request.setValue(authentication?.userAgent, forHTTPHeaderField: "User-Agent")
        } else {
            request.setValue("FluxDO-ShareExtension", forHTTPHeaderField: "User-Agent")
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        guard request.url?.scheme == "https", request.url?.user == nil, request.url?.password == nil,
              request.url?.port == nil || request.url?.port == 443 else {
            completionHandler(nil)
            return
        }
        var redirected = request
        applyAuthentication(to: &redirected)
        completionHandler(redirected)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let transfer = transfers[dataTask.taskIdentifier] else { completionHandler(.cancel); return }
        let mime = response.mimeType?.lowercased() ?? ""
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              ["image/png", "image/jpeg", "image/gif", "image/webp", "image/avif", "image/heic", "image/heif", "image/svg+xml"].contains(mime),
              response.expectedContentLength <= 16 * 1024 * 1024 else {
            fail(dataTask, error: ShareImageError.message("正文图片无法加载；如需登录或 Cloudflare 验证，请先到 FluxDO 完成验证并同步会话，再重新分享。"))
            completionHandler(.cancel)
            return
        }
        let safeResponse = URLResponse(url: transfer.schemeTask.request.url!, mimeType: mime,
                                       expectedContentLength: Int(response.expectedContentLength), textEncodingName: nil)
        transfer.schemeTask.didReceive(safeResponse)
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard var transfer = transfers[dataTask.taskIdentifier] else { return }
        transfer.bytes += data.count
        guard transfer.bytes <= 16 * 1024 * 1024 else {
            fail(dataTask, error: ShareImageError.message("单张正文图片超过 16 MB，请使用文章导出。"))
            return
        }
        transfers[dataTask.taskIdentifier] = transfer
        transfer.schemeTask.didReceive(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let transfer = transfers.removeValue(forKey: task.taskIdentifier) else { return }
        tasks.removeValue(forKey: ObjectIdentifier(transfer.schemeTask))
        if let error = error { transfer.schemeTask.didFailWithError(error) }
        else { transfer.schemeTask.didFinish() }
    }

    private func fail(_ task: URLSessionTask, error: Error) {
        guard let transfer = transfers.removeValue(forKey: task.taskIdentifier) else { return }
        tasks.removeValue(forKey: ObjectIdentifier(transfer.schemeTask))
        transfer.schemeTask.didFailWithError(error)
        task.cancel()
    }
}

/// WebKit 不会自动响应 Swift Task 取消，主动结束等待并丢弃迟到回调。
private final class ShareRenderCompletion<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?

    init(_ continuation: CheckedContinuation<Value, Error>) {
        self.continuation = continuation
    }

    func finish(_ result: Result<Value, Error>) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}
