import UIKit
import UniformTypeIdentifiers
import WebKit

@MainActor
final class ShareViewController: UIViewController, UIAdaptivePresentationControllerDelegate {
    typealias TopicLoader = () async throws -> (link: SharedTopicLink, client: ForumShareClient, topic: SharedTopic)
    private enum PageState { case loading, failed, ready, verifying }
    private let topicLoader: TopicLoader?
    private var pageState = PageState.loading
    private var needsVerification = false
    private let contentStack = UIStackView()

    init(topicLoader: @escaping TopicLoader) {
        self.topicLoader = topicLoader
        super.init(nibName: nil, bundle: nil)
    }

    override init(nibName nibNameOrNil: String?, bundle nibBundleOrNil: Bundle?) {
        topicLoader = nil
        super.init(nibName: nibNameOrNil, bundle: nibBundleOrNil)
    }

    required init?(coder: NSCoder) {
        topicLoader = nil
        super.init(coder: coder)
    }
    private var work: Task<Void, Never>?
    private var operationID = UUID()
    private var closed = false
    private var providerProgress: [Progress] = []
    private var client: ForumShareClient?
    private var topic: SharedTopic?
    private var link: SharedTopicLink?
    private var activePreview: UIViewController?
    private var workingDirectory: URL?
    private var previousDirectories: [URL] = []
    private var retryAction: (() -> Void)?
    private var webSession: ShareWebSession?
    private var preparedHost: String?
    private var preferredBrowserHost: String?
    private var browserHost: String?
    private var browserPreparation: (id: UUID, task: Task<Void, Error>)?
    private var sessionDiagnostic = "SESSION_NOT_READ"
    private let verificationContainer = UIStackView()
    private let verificationButton = UIButton(type: .system)
    private let continueButton = UIButton(type: .system)
    private let clearSessionButton = UIButton(type: .system)
    private let diagnosticButton = UIButton(type: .system)

    private let titleLabel = UILabel()
    private let statusLabel = UILabel()
    private let sessionHint = UILabel()
    private let imageButton = UIButton(type: .system)
    private let exportButton = UIButton(type: .system)
    private let spinner = UIActivityIndicatorView(style: .medium)
    private var navigationBar: UINavigationBar!

    override func viewDidLoad() {
        super.viewDidLoad()
        configureUI()
        configureSheet()
        beginLoading()
    }

    private func configureUI() {
        view.backgroundColor = .systemBackground
        preferredContentSize = CGSize(width: 440, height: 180)
        view.accessibilityIdentifier = "shareEntry.root"
        navigationBar = UINavigationBar()
        navigationBar.translatesAutoresizingMaskIntoConstraints = false
        let item = UINavigationItem(title: "FluxDO 分享")
        item.leftBarButtonItem = UIBarButtonItem(title: "取消", style: .plain, target: self, action: #selector(closeCancelled))
        item.leftBarButtonItem?.accessibilityIdentifier = "shareEntry.close"
        navigationBar.items = [item]
        view.addSubview(navigationBar)

        let scroll = UIScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.backgroundColor = .systemBackground
        view.addSubview(scroll)
        let stack = contentStack
        stack.axis = .vertical
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            navigationBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            navigationBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            navigationBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: navigationBar.bottomAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -16),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -16),
            stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -32)
        ])
        titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.accessibilityIdentifier = "shareEntry.title"
        titleLabel.numberOfLines = 0
        titleLabel.text = "正在读取分享链接…"
        stack.addArrangedSubview(titleLabel)
        statusLabel.font = .preferredFont(forTextStyle: .subheadline)
        statusLabel.textColor = .secondaryLabel
        statusLabel.numberOfLines = 0
        statusLabel.accessibilityTraits = .updatesFrequently
        statusLabel.accessibilityIdentifier = "shareEntry.status"
        stack.addArrangedSubview(statusLabel)
        sessionHint.font = .preferredFont(forTextStyle: .footnote)
        sessionHint.textColor = .secondaryLabel
        sessionHint.numberOfLines = 0
        sessionHint.isHidden = true
        stack.addArrangedSubview(sessionHint)
        stack.addArrangedSubview(spinner)
        spinner.accessibilityIdentifier = "shareEntry.progress"
        configureButton(verificationButton, title: "验证 / 登录", action: #selector(recover))
        verificationButton.accessibilityIdentifier = "shareEntry.recover"
        stack.addArrangedSubview(verificationButton)
        verificationContainer.axis = .vertical
        verificationContainer.spacing = 10
        verificationContainer.isHidden = true
        verificationContainer.accessibilityIdentifier = "shareEntry.verification"
        let verificationHint = UILabel()
        verificationHint.text = "请在此网页完成验证或登录，帖子可正常打开后点击继续。扩展会保留自己的登录状态，下次分享可复用。"
        verificationHint.numberOfLines = 0
        verificationHint.font = .preferredFont(forTextStyle: .footnote)
        verificationContainer.addArrangedSubview(verificationHint)
        configureButton(continueButton, title: "验证完成，继续保存", action: #selector(continueAfterVerification))
        continueButton.accessibilityIdentifier = "shareEntry.continue"
        verificationContainer.addArrangedSubview(continueButton)
        stack.addArrangedSubview(verificationContainer)
        configureButton(clearSessionButton, title: "退出扩展登录", action: #selector(clearExtensionSession))
        clearSessionButton.accessibilityIdentifier = "shareEntry.clearSession"
        stack.addArrangedSubview(clearSessionButton)
        configureButton(diagnosticButton, title: "分享扩展诊断", action: #selector(shareDiagnostics))
        diagnosticButton.accessibilityIdentifier = "shareEntry.diagnostics"
        stack.addArrangedSubview(diagnosticButton)

        configureButton(imageButton, title: "分享图片", action: #selector(generateImages))
        imageButton.accessibilityIdentifier = "shareEntry.image"
        stack.addArrangedSubview(imageButton)
        configureButton(exportButton, title: "导出文章", action: #selector(generateExport))
        exportButton.accessibilityIdentifier = "shareEntry.export"
        stack.addArrangedSubview(exportButton)
        updatePage(.loading)
    }

    private func configureSheet() {
        guard let sheet = sheetPresentationController else { return }
        sheet.prefersGrabberVisible = true
        if #available(iOS 16.0, *) {
            sheet.detents = [.custom(identifier: .init("shareEntry.compact")) { [weak self] context in
                min(context.maximumDetentValue, self?.preferredContentSize.height ?? 180)
            }]
        } else {
            sheet.detents = [.medium(), .large()]
        }
    }

    private func configureButton(_ button: UIButton, title: String, action: Selector) {
        var configuration = UIButton.Configuration.tinted()
        configuration.title = title
        configuration.cornerStyle = .medium
        button.configuration = configuration
        button.addTarget(self, action: action, for: .touchUpInside)
        let height = button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44)
        height.priority = UILayoutPriority(999)
        height.isActive = true
    }

    private func beginLoading() {
        start(message: "正在读取链接并加载主题…", retry: { [weak self] in self?.beginLoading() }) { [weak self] id in
            guard let self = self else { return }
            if let loader = self.topicLoader {
                let loaded = try await loader()
                try self.ensureActive(id)
                self.link = loaded.link
                self.client = loaded.client
                self.display(loaded.topic, host: loaded.link.host)
                return
            }
            let link = try await self.receiveLink()
            try self.ensureActive(id)
            self.link = link
            self.topic = nil
            self.client = nil
            let browser: ShareWebSession
            if let existing = self.webSession, self.browserHost == link.host {
                browser = existing
            } else {
                self.webSession?.cancel()
                self.webSession?.webView.removeFromSuperview()
                browser = ShareWebSession(host: link.host)
                self.webSession = browser
                self.browserHost = link.host
                self.preparedHost = nil
                self.preferredBrowserHost = nil
                let height = browser.webView.heightAnchor.constraint(equalToConstant: 320)
                height.priority = UILayoutPriority(999)
                height.isActive = true
                self.verificationContainer.insertArrangedSubview(browser.webView, at: 1)
            }
            var seed: ShareSession?
            do {
                seed = try ShareSessionStore.readSession(host: link.host)
                self.sessionDiagnostic = "SHARED_SESSION_READ"
                self.sessionHint.text = nil
            } catch {
                self.sessionDiagnostic = self.sessionCode(error)
                self.sessionHint.text = "共享会话暂不可用，将使用扩展自身会话尝试接口；需要时会自动打开验证网页。"
                self.sessionHint.isHidden = true
            }
            self.verificationContainer.isHidden = true
            try await browser.seed(session: seed)
            try self.ensureActive(id)
            let cookieEpoch = browser.cookieEpoch
            let client = ForumShareClient(link: link,
                sessionProvider: { [weak browser] url in
                    guard let browser = browser else { throw CancellationError() }
                    return try await browser.nativeSession(for: url)
                }, responseHandler: { [weak browser] response in
                    await browser?.receiveCookies(from: response, epoch: cookieEpoch)
                }, fallbackLoader: { [weak self, weak browser] url in
                    guard let self = self, let browser = browser else { throw CancellationError() }
                    try await self.prepareBrowser(link: link)
                    return try await browser.request(url)
                }, fallbackImageLoader: { [weak self, weak browser] url in
                    guard let self = self, let browser = browser else { throw CancellationError() }
                    try await self.prepareBrowser(link: link)
                    return try await browser.image(url)
                }, startsInBrowser: self.preferredBrowserHost == link.host)
            self.client = client
            let topic = try await client.loadTopic()
            try self.ensureActive(id)
            self.display(topic, host: link.host)
        }
    }

    private func prepareBrowser(link: SharedTopicLink, showVerification: Bool = false) async throws {
        try Task.checkCancellation()
        guard !closed, let browser = webSession, browserHost == link.host else { throw CancellationError() }
        preferredBrowserHost = link.host
        if preparedHost == link.host { return }
        if let preparation = browserPreparation {
            try await preparation.task.value
            try Task.checkCancellation()
            return
        }
        let id = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self = self else { throw CancellationError() }
            if showVerification {
                self.updatePage(.verifying)
                self.statusLabel.text = "请完成验证或登录，再点击“验证完成，继续保存”。"
            } else {
                self.statusLabel.text = "接口读取失败，正在使用网页会话重试…"
            }
            try await browser.prepare(url: link.url, session: nil)
            try Task.checkCancellation()
            guard !self.closed else { throw CancellationError() }
            self.preparedHost = link.host
            if !showVerification { self.verificationContainer.isHidden = true }
        }
        browserPreparation = (id, task)
        defer { if browserPreparation?.id == id { browserPreparation = nil } }
        try await withTaskCancellationHandler(operation: {
            try await task.value
            try Task.checkCancellation()
        }, onCancel: { task.cancel() })
    }

    private func sessionCode(_ error: Error) -> String {
        guard let error = error as? ShareSessionStore.StoreError else { return "SESSION_READ_FAILED" }
        switch error {
        case .unavailableGroup: return "SHARE_SESSION_UNAVAILABLE"
        case .missingSession: return "SESSION_MISSING"
        case .expiredSession: return "SESSION_EXPIRED"
        case .invalidSession: return "SESSION_INVALID"
        case .unsupportedHost: return "UNSUPPORTED_HOST"
        case .fileOperation(let code): return "SESSION_FILE_\(code)"
        }
    }

    @objc private func showVerification() {
        guard let link = link, webSession != nil else { beginLoading(); return }
        if preparedHost == link.host {
            verificationContainer.isHidden = false
            updatePage(.verifying)
            if webSession?.webView.isLoading == false { webSession?.webView.reload() }
        } else {
            start(message: "正在打开验证网页…", retry: retryAction ?? { [weak self] in self?.beginLoading() }) { [weak self] id in
                guard let self = self else { return }
                do {
                    try await self.prepareBrowser(link: link, showVerification: true)
                } catch ForumShareError.network {
                    // 导航超时后仍保留网页，允许用户继续完成验证。
                }
                try self.ensureActive(id)
                self.updatePage(.verifying)
                self.statusLabel.text = "请完成验证或登录，再点击“验证完成，继续保存”。"
            }
        }
    }

    @objc private func continueAfterVerification() {
        guard let browser = webSession, let link = link, let retry = retryAction else { return }
        guard browser.webView.url?.host?.lowercased() != link.host else { retry(); return }
        // SSO 可能停留在登录服务域；用户明确继续后回到帖子原站再重做原操作。
        start(message: "正在返回帖子并继续保存…", retry: retry) { [weak self] id in
            try await browser.prepare(url: link.url, session: nil)
            guard let self = self else { return }
            try self.ensureActive(id)
            self.preparedHost = link.host
            retry()
        }
    }

    @objc private func clearExtensionSession() {
        let alert = UIAlertController(title: "退出扩展登录？", message: "将清除分享扩展内两个站点的登录和验证状态。主应用的登录保持原样。", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "退出", style: .destructive) { [weak self] _ in
            guard let self = self, let browser = self.webSession else { return }
            self.start(message: "正在清除扩展会话…", retry: { [weak self] in self?.beginLoading() }) { [weak self] id in
                await browser.clear()
                guard let self = self else { return }
                try self.ensureActive(id)
                self.preparedHost = nil
                self.preferredBrowserHost = nil
                self.topic = nil
                self.client = nil
                self.sessionDiagnostic = "EXTENSION_SESSION_CLEARED"
                self.needsVerification = false
                self.verificationContainer.isHidden = true
                self.statusLabel.text = "已退出扩展登录。下次加载可使用共享会话或在扩展内重新登录。"
                self.updatePage(.failed)
            }
        })
        present(alert, animated: true)
    }

    @objc private func shareDiagnostics() {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "未知"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "未知"
        let report = """
        FluxDO 分享扩展
        版本：\(version)+\(build)
        站点：\(link?.host ?? "未知")
        共享会话：\(sessionDiagnostic)
        请求通道：\(client?.requestChannel ?? "尚未请求")
        接口回退原因：\(client?.nativeFailure ?? "无")
        最近 HTTP 状态：\((client?.lastHTTPStatus).map { String($0) } ?? "尚无响应")
        验证界面：\(verificationContainer.isHidden ? "隐藏" : "显示")
        """
        let activity = UIActivityViewController(activityItems: [report], applicationActivities: nil)
        activity.popoverPresentationController?.sourceView = diagnosticButton
        activity.popoverPresentationController?.sourceRect = diagnosticButton.bounds
        present(activity, animated: true)
    }

    private func receiveLink() async throws -> SharedTopicLink {
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
        var sawText = false
        var parseError: Error?
        for provider in providers {
            for type in [UTType.url.identifier, UTType.plainText.identifier] where provider.hasItemConformingToTypeIdentifier(type) {
                try Task.checkCancellation()
                let text: String
                do {
                    text = try await loadProviderText(provider, type: type)
                } catch {
                    parseError = error
                    continue
                }
                try Task.checkCancellation()
                sawText = true
                do { return try SharedTopicLink.parse(text) }
                catch { parseError = error }
            }
        }
        if let error = parseError { throw error }
        throw ShareUIError.message(sawText ? "没有找到受支持的主题链接。" : "请从浏览器或其他应用分享 linux.do / idcflare.com 的主题链接或含链接的文本。")
    }

    private func loadProviderText(_ provider: NSItemProvider, type: String) async throws -> String {
        let state = ShareInputContinuation()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                guard state.bind(continuation) else { return }
                let progress: Progress
                if type == UTType.url.identifier, provider.canLoadObject(ofClass: NSURL.self) {
                    progress = provider.loadObject(ofClass: NSURL.self) { value, error in
                        if let error = error { state.resume(throwing: error) }
                        else if let url = value as? URL { state.resume(returning: url.absoluteString) }
                        else { state.resume(throwing: ShareUIError.message("无法读取分享的链接。")) }
                    }
                } else if provider.canLoadObject(ofClass: NSString.self) {
                    progress = provider.loadObject(ofClass: NSString.self) { value, error in
                        if let error = error { state.resume(throwing: error) }
                        else if let string = value as? String { state.resume(returning: string) }
                        else { state.resume(throwing: ShareUIError.message("无法读取分享的文本。")) }
                    }
                } else {
                    progress = provider.loadDataRepresentation(forTypeIdentifier: type) { data, error in
                        if let error = error { state.resume(throwing: error) }
                        else if let data = data, let string = String(data: data, encoding: .utf8) {
                            state.resume(returning: string)
                        } else { state.resume(throwing: ShareUIError.message("分享内容不是有效的 UTF-8 链接或文本。")) }
                    }
                }
                providerProgress.append(progress)
            }
        }, onCancel: { state.resume(throwing: CancellationError()) })
    }

    @objc private func generateImages() {
        guard let client = client, let topic = topic, let post = topic.posts.first(where: { $0.postNumber == 1 }),
              presentedViewController == nil else { return }
        do {
            let preview = ShareImagePreviewController(topic: topic, post: post, directory: try makeDirectory(),
                imageLoader: { url in try await client.image(url) },
                onAuthenticationRequired: { [weak self] in self?.verifyForPreview() })
            activePreview = preview
            present(preview, animated: true)
        } catch { statusLabel.text = "无法创建图片预览，请重试。" }
    }

    @objc private func generateExport() {
        guard let client = client, let topic = topic, presentedViewController == nil else { return }
        do {
            let preview = ShareExportViewController(topic: topic, client: client, directory: try makeDirectory(),
                onAuthenticationRequired: { [weak self] in self?.verifyForPreview() })
            activePreview = preview
            present(preview, animated: true)
        } catch { statusLabel.text = "无法创建导出界面，请重试。" }
    }

    private func verifyForPreview() {
        guard let preview = activePreview else { return }
        dismiss(animated: true) { [weak self] in
            guard let self = self, !self.closed else { return }
            self.needsVerification = true
            self.updatePage(.verifying)
            self.statusLabel.text = "请完成网页验证，再点击“验证完成，继续保存”返回原界面。"
            self.retryAction = { [weak self, preview] in
                guard let self = self, !self.closed, self.presentedViewController == nil else { return }
                self.updatePage(.ready)
                self.present(preview, animated: true) {
                    (preview as? ShareImagePreviewController)?.resumeAfterAuthentication()
                    (preview as? ShareExportViewController)?.resumeAfterAuthentication()
                }
            }
        }
    }

    private func start(message: String, retry: @escaping () -> Void,
                       operation: @escaping (UUID) async throws -> Void) {
        guard !closed else { return }
        stopWork()
        let id = UUID()
        operationID = id
        retryAction = retry
        updatePage(.loading)
        statusLabel.text = message
        work = Task { [weak self] in
            do {
                try await operation(id)
                guard let self = self, !self.closed, self.operationID == id else { return }
                if self.pageState == .loading { self.updatePage(self.topic == nil ? .failed : .ready) }
                self.work = nil
                self.providerProgress.removeAll()
            } catch {
                guard let self = self, !self.closed, self.operationID == id else { return }
                self.needsVerification = false
                self.work = nil
                self.providerProgress.removeAll()
                if error is CancellationError {
                    self.statusLabel.text = "已停止操作，可重试。"
                } else {
                    if let message = (error as? ForumShareError)?.errorDescription
                        ?? (error as? ShareImageError)?.errorDescription
                        ?? (error as? ShareUIError)?.errorDescription {
                        self.statusLabel.text = message
                    } else {
                        self.statusLabel.text = "操作失败，请重试或分享扩展诊断。"
                    }
                    if let forumError = error as? ForumShareError {
                        switch forumError {
                        case .cloudflare, .loginRequired, .accessDenied:
                            self.needsVerification = true
                        case .network:
                            self.needsVerification = self.client?.usesBrowser == true && self.webSession != nil
                        default: break
                        }
                    }
                }
                self.updatePage(.failed)
            }
        }
    }

    private func ensureActive(_ id: UUID) throws {
        try Task.checkCancellation()
        if closed || id != operationID { throw CancellationError() }
    }

    private func display(_ topic: SharedTopic, host: String) {
        self.topic = topic
        needsVerification = false
        titleLabel.text = topic.title
        statusLabel.text = "\(host) · 已加载主帖"
        updatePage(.ready)
    }

    private func updatePage(_ state: PageState) {
        pageState = state
        let loading = state == .loading
        let failed = state == .failed
        let ready = state == .ready
        titleLabel.isHidden = !ready
        sessionHint.isHidden = !failed || sessionHint.text == nil
        verificationButton.isHidden = !failed
        clearSessionButton.isHidden = !failed
        diagnosticButton.isHidden = !failed
        imageButton.isHidden = !ready
        exportButton.isHidden = !ready
        imageButton.isEnabled = ready && topic != nil && client != nil
        exportButton.isEnabled = imageButton.isEnabled
        clearSessionButton.isEnabled = webSession != nil
        verificationContainer.isHidden = state != .verifying
        verificationContainer.spacing = state == .verifying ? 10 : 0
        continueButton.isEnabled = state == .verifying
        verificationButton.configuration?.title = needsVerification ? "验证 / 登录" : "重试"
        navigationBar.items?.first?.rightBarButtonItem = state == .verifying
            ? UIBarButtonItem(title: "返回", style: .plain, target: self, action: #selector(hideVerification)) : nil
        spinner.isHidden = !loading
        if loading { spinner.startAnimating() } else { spinner.stopAnimating() }
        if #unavailable(iOS 16.0) {
            sheetPresentationController?.selectedDetentIdentifier = state == .verifying ? .large : .medium
        }
        updateHeight()
    }

    private func updateHeight() {
        guard view.bounds.width > 32 else { return }
        let width = view.bounds.width - 32
        let content = contentStack.systemLayoutSizeFitting(
            CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel
        )
        let limit = max(320, (view.window?.windowScene?.screen.bounds.height ?? 800) - 100)
        let height = min(limit, max(180, content.height + 84))
        let size = CGSize(width: 440, height: height)
        if abs(preferredContentSize.height - height) > 1 {
            preferredContentSize = size
            if #available(iOS 16.0, *) { sheetPresentationController?.invalidateDetents() }
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateHeight()
    }

    @objc private func recover() {
        if needsVerification { showVerification() } else { retryAction?() }
    }

    @objc private func hideVerification() {
        stopWork()
        updatePage(.failed)
    }

    private func stopWork() {
        operationID = UUID()
        work?.cancel()
        webSession?.cancel()
        browserPreparation?.task.cancel()
        browserPreparation = nil
        work = nil
        providerProgress.forEach { $0.cancel() }
        providerProgress.removeAll()
    }

    private func makeDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FluxDOShare", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // 上一次取消或系统终止留下的文件延迟一天清理，不影响刚交付给其他应用的文件。
        let active = Set(previousDirectories + (workingDirectory.map { [$0] } ?? []))
        if let children = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.creationDateKey]) {
            let cutoff = Date().addingTimeInterval(-24 * 60 * 60)
            for child in children where !active.contains(child) {
                if let created = try? child.resourceValues(forKeys: [.creationDateKey]).creationDate, created < cutoff {
                    try? FileManager.default.removeItem(at: child)
                }
            }
        }
        let directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let old = workingDirectory { previousDirectories.append(old) }
        workingDirectory = directory
        return directory
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        presentationController?.delegate = self
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if !closed && presentedViewController == nil && view.window == nil {
            close(cancelled: true)
        }
    }

    override func didMove(toParent parent: UIViewController?) {
        super.didMove(toParent: parent)
        if parent == nil, isViewLoaded, view.window == nil, !closed {
            close(cancelled: true)
        }
    }

    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        close(cancelled: true)
    }

    deinit {
        work?.cancel()
        providerProgress.forEach { $0.cancel() }
    }

    @objc private func closeCancelled() { close(cancelled: true) }

    private func close(cancelled: Bool) {
        guard !closed else { return }
        closed = true
        stopWork()
        guard let context = extensionContext else {
            dismiss(animated: true)
            return
        }
        let directories = previousDirectories + (workingDirectory.map { [$0] } ?? [])
        // 仅在扩展结束且系统确认交付后删除，系统分享/文件选择器取消不会触发清理。
        let cleanup: (Bool) -> Void = { _ in
            directories.forEach { try? FileManager.default.removeItem(at: $0) }
        }
        if cancelled {
            // cancelRequest 没有交付完成回调，保留临时文件由系统清理，避免接收方仍在读取。
            context.cancelRequest(withError: NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError))
        } else {
            context.completeRequest(returningItems: nil, completionHandler: cleanup)
        }
    }
}

private enum ShareUIError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let text): return text }
    }
}

private final class ShareInputContinuation: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<String, Error>?
    private var result: Result<String, Error>?

    func bind(_ continuation: CheckedContinuation<String, Error>) -> Bool {
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

    func resume(returning text: String) { finish(.success(text)) }
    func resume(throwing error: Error) { finish(.failure(error)) }

    private func finish(_ result: Result<String, Error>) {
        lock.lock()
        guard self.result == nil else { lock.unlock(); return }
        self.result = result
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}
