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

    var previewView: WKWebView? { webView }
    private var contentHeight: CGFloat = 0

    func prepare(html: String, host: String, container: UIView,
                 imageLoader: ForumShareClient.Loader? = nil) async throws {
        cancel()
        cancelled = false
        let proxy = ShareImageProxy(host: host, session: ShareSessionStore.read(host: host), loader: imageLoader)
        imageProxy = proxy
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.setURLSchemeHandler(proxy, forURLScheme: "fluxdo-share-image")
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 375, height: 600), configuration: configuration)
        web.scrollView.contentInsetAdjustmentBehavior = .never
        web.navigationDelegate = self
        web.isOpaque = true
        web.accessibilityIdentifier = "shareImage.preview"
        container.addSubview(web)
        webView = web
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            navigation = continuation
            navigationTimeout = Task { [weak self] in
                do { try await Task.sleep(nanoseconds: 60_000_000_000) } catch { return }
                self?.navigation?.resume(throwing: ShareImageError.message("正文排版加载超时，请重试。"))
                self?.navigation = nil
                self?.webView?.stopLoading()
            }
            web.loadHTMLString(html, baseURL: nil)
        }
        navigationTimeout?.cancel()
        navigationTimeout = nil
        try checkCancellation()
        contentHeight = try await measureContent(in: web)
    }

    func selectTheme(_ theme: ShareImagePalette) async throws {
        guard let web = webView else { throw ShareImageError.message("图片预览尚未准备好。") }
        try checkCancellation()
        _ = try await execute(ShareImagePalette.themeUpdateScript(theme), in: web)
    }

    private func measureContent(in web: WKWebView) async throws -> CGFloat {
        let script = """
        const ready = async () => {
          document.querySelectorAll('details').forEach(details => { details.open = true; });
          await document.fonts.ready;
          await Promise.all(Array.from(document.images).map(image => {
            image.loading = 'eager';
            return image.decode().catch(() => {
              if (image.classList.contains('avatar')) {
                const fallback=document.createElement('div');
                fallback.className='avatar avatar-fallback';
                fallback.textContent=(document.querySelector('.display-name')?.textContent || '?').slice(0,1);
                image.replaceWith(fallback);
                return;
              }
              throw new Error('正文图片加载失败');
            });
          }));
          await new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)));
          if (Math.max(document.documentElement.scrollWidth, document.body.scrollWidth) > window.innerWidth + 1) {
            throw new Error('正文包含超宽内容');
          }
          return Math.ceil(document.getElementById('share-card').getBoundingClientRect().height);
        };
        return await Promise.race([ready(), new Promise((_, reject) => setTimeout(() => reject(new Error('图片或字体加载超时')), 45000))]);
        """
        let result: Any?
        do { result = try await execute(script, in: web) }
        catch {
            if let error = imageProxy?.authenticationFailure { throw error }
            throw ShareImageError.message("正文排版或图片加载失败，请重试；超宽内容可使用 HTML 导出。")
        }
        try checkCancellation()
        guard let height = result as? NSNumber, height.doubleValue.isFinite, height.doubleValue > 0 else {
            throw ShareImageError.message("无法获取完整正文高度。")
        }
        return CGFloat(height.doubleValue)
    }

    func capture(to file: URL, progress: @escaping (String) -> Void) async throws -> URL {
        guard let web = webView else { throw ShareImageError.message("图片预览尚未准备好。") }
        try checkCancellation()
        contentHeight = try await measureContent(in: web)
        let oldBounds = web.bounds
        let oldCenter = web.center
        let oldTransform = web.transform
        let oldOffset = web.scrollView.contentOffset
        web.transform = .identity
        web.frame = CGRect(x: 0, y: 0, width: 375, height: 1000)
        web.scrollView.isScrollEnabled = false
        defer {
            web.bounds = oldBounds
            web.center = oldCenter
            web.transform = oldTransform
            web.scrollView.isScrollEnabled = true
            web.scrollView.setContentOffset(oldOffset, animated: false)
        }
        let totalPixels = Int(ceil(contentHeight * 2))
        guard totalPixels <= 200_000 else {
            throw ShareImageError.message("文章超过长图安全尺寸，请使用 HTML 导出。")
        }
        let writer = try ShareLongImageEncoder(url: file, width: 750, height: totalPixels)
        var complete = false
        defer { if !complete { Task { await writer.cancel() } } }
        let count = Int(ceil(CGFloat(totalPixels) / 2000))
        for index in 0..<count {
            try checkCancellation()
            progress("正在生成完整长图 \(index + 1)/\(count)…")
            let startPixels = index * 2000
            let rows = min(2000, totalPixels - startPixels)
            let start = CGFloat(startPixels) / 2
            let sliceHeight = CGFloat(rows) / 2
            let scrollOffset = min(start, max(0, contentHeight - 1000))
            web.scrollView.setContentOffset(CGPoint(x: 0, y: scrollOffset), animated: false)
            _ = try await execute("await new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve))); return true;", in: web)
            try checkCancellation()
            let origin = start - web.scrollView.contentOffset.y
            guard origin >= -0.5, origin + sliceHeight <= 1000.5 else {
                throw ShareImageError.message("无法取得完整长图，已停止输出以避免截断。")
            }
            let configuration = WKSnapshotConfiguration()
            configuration.rect = CGRect(x: 0, y: max(0, origin), width: 375, height: sliceHeight)
            configuration.snapshotWidth = 375
            configuration.afterScreenUpdates = true
            let image = try await takeSnapshot(of: web, configuration: configuration)
            try checkCancellation()
            let pixels = try autoreleasepool { () throws -> CGImage in
                let format = UIGraphicsImageRendererFormat()
                format.scale = 2
                format.opaque = true
                let size = CGSize(width: 375, height: CGFloat(rows) / 2)
                let normalized = UIGraphicsImageRenderer(size: size, format: format).image { _ in
                    image.draw(in: CGRect(origin: .zero, size: size))
                }
                guard let pixels = normalized.cgImage else { throw ShareImageError.message("无法读取截图像素。") }
                return pixels
            }
            try await writer.append(pixels, rows: rows)
            try checkCancellation()
        }
        try await writer.finish()
        complete = true
        return file
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
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Any?, Error>) in
            let completion = ShareRenderCompletion<Any?>(continuation)
            cancelPending = { completion.finish(.failure($0)) }
            navigationTimeout = timeout(completion)
            web.callAsyncJavaScript(script, arguments: [:], in: nil, in: .defaultClient) { result in
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

enum ShareImageError: LocalizedError {
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
    private static let imageTypes: Set<String> = ["image/png", "image/jpeg", "image/gif", "image/webp", "image/avif", "image/heic", "image/heif", "image/svg+xml"]
    private(set) var authenticationFailure: ForumShareError?
    private let host: String
    private let authentication: ShareSession?
    private let loader: ForumShareClient.Loader?
    private var browserTasks: [ObjectIdentifier: Task<Void, Never>] = [:]
    private var transfers: [Int: Transfer] = [:]
    private var tasks: [ObjectIdentifier: URLSessionDataTask] = [:]
    private var session: URLSession!

    init(host: String, session authentication: ShareSession?, loader: ForumShareClient.Loader?) {
        self.host = host.lowercased()
        self.authentication = authentication
        self.loader = loader
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
        if url.host?.lowercased() == host, let loader = loader {
            let key = ObjectIdentifier(urlSchemeTask)
            browserTasks[key] = Task { @MainActor [weak self] in
                do {
                    let (data, response) = try await loader(url)
                    try Task.checkCancellation()
                    guard let self = self, self.browserTasks.removeValue(forKey: key) != nil else { return }
                    let mime = response.mimeType?.lowercased() ?? ""
                    if response.statusCode == 403 || response.value(forHTTPHeaderField: "cf-mitigated") == "challenge" {
                        self.authenticationFailure = .cloudflare
                    } else if response.statusCode == 401 {
                        self.authenticationFailure = .loginRequired
                    }
                    guard (200..<300).contains(response.statusCode),
                          Self.imageTypes.contains(mime), data.count <= 16 * 1024 * 1024 else {
                        urlSchemeTask.didFailWithError(ShareImageError.message("正文图片无法加载，请在扩展内验证后重试。"))
                        return
                    }
                    let safe = URLResponse(url: urlSchemeTask.request.url!, mimeType: mime,
                                           expectedContentLength: data.count, textEncodingName: nil)
                    urlSchemeTask.didReceive(safe)
                    urlSchemeTask.didReceive(data)
                    urlSchemeTask.didFinish()
                } catch {
                    guard let self = self, self.browserTasks.removeValue(forKey: key) != nil else { return }
                    if let forum = error as? ForumShareError {
                        switch forum {
                        case .cloudflare, .loginRequired, .accessDenied: self.authenticationFailure = forum
                        default: break
                        }
                    }
                    urlSchemeTask.didFailWithError(ShareImageError.message("正文图片加载失败，请在扩展内验证后重试。"))
                }
            }
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
        browserTasks.removeValue(forKey: ObjectIdentifier(urlSchemeTask))?.cancel()
        guard let task = tasks.removeValue(forKey: ObjectIdentifier(urlSchemeTask)) else { return }
        transfers.removeValue(forKey: task.taskIdentifier)
        task.cancel()
    }

    func cancel() {
        browserTasks.values.forEach { $0.cancel() }
        browserTasks.removeAll()
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
              Self.imageTypes.contains(mime),
              response.expectedContentLength <= 16 * 1024 * 1024 else {
            fail(dataTask, error: ShareImageError.message("正文图片无法加载；可在扩展内验证或登录后重试。"))
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

/// 逐行像素转换与 zlib 压缩在串行 actor 上执行，截图和预览交互保留在主线程。
private actor ShareLongImageEncoder {
    private let writer: ShareLongImageWriter
    init(url: URL, width: Int, height: Int) throws {
        writer = try ShareLongImageWriter(url: url, width: width, height: height)
    }
    func append(_ image: CGImage, rows: Int) throws { try writer.append(image, rows: rows) }
    func finish() throws { try writer.finish() }
    func cancel() { writer.cancel() }
}
