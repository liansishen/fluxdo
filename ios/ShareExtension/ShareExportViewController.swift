import UIKit

/// 分享扩展的独立导出页：范围 → 格式 → 去向，在本页生成并直接保存或分享。
/// 验证回调后父 dismiss；同一实例重新 present 后点“重试”继续，不自动生成。
@MainActor
final class ShareExportViewController: UIViewController, UIDocumentPickerDelegate {
    private enum Format: String { case markdown, html }
    private enum Scope: String { case firstPost, allPosts }
    private enum Delivery { case save, share }

    private struct CachedFile {
        let url: URL
        let postCount: Int
    }

    private static let maxMarkdownPosts = 10
    private let topic: SharedTopic
    private let client: ForumShareClient
    private let directory: URL
    private let onAuthenticationRequired: () -> Void
    private let navigationBar = UINavigationBar()
    private let scopeControl: UISegmentedControl
    private let formatControl = UISegmentedControl(items: ["Markdown", "HTML"])
    private let hintLabel = UILabel()
    private let statusLabel = UILabel()
    private let stopButton = UIButton(type: .system)
    private let retryButton = UIButton(type: .system)
    private let saveRow = UIButton(type: .system)
    private let shareRow = UIButton(type: .system)
    private var work: Task<Void, Never>?
    private var generationID = UUID()
    private var cachedFiles: [String: CachedFile] = [:]
    private var lastDelivery: Delivery = .save
    private var busy = false

    init(topic: SharedTopic, client: ForumShareClient, directory: URL,
         onAuthenticationRequired: @escaping () -> Void) {
        self.topic = topic
        self.client = client
        self.directory = directory
        self.onAuthenticationRequired = onAuthenticationRequired
        scopeControl = UISegmentedControl(items: ["仅主帖", "全部楼层（\(topic.postIDs.count)）"])
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .pageSheet
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("不支持从归档创建导出界面")
    }
    override func viewDidLoad() {
        super.viewDidLoad()
        configureUI()
        updateHints()
        statusLabel.text = "选择范围、格式和去向；生成后可直接保存或分享。"
        if let sheet = sheetPresentationController {
            sheet.detents = [.large()]
            sheet.prefersGrabberVisible = true
        }
    }
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        // 只取消任务，不标记关闭：父因验证 dismiss 后可能重新 present 同一实例。
        if isBeingDismissed {
            let wasBusy = busy
            stopWork()
            setBusy(false)
            if wasBusy { statusLabel.text = "已停止生成，选项已保留，可重试。" }
        }
    }
    private func configureUI() {
        view.backgroundColor = .systemBackground
        view.tintColor = .systemOrange
        navigationBar.translatesAutoresizingMaskIntoConstraints = false
        let item = UINavigationItem(title: "导出文章")
        item.leftBarButtonItem = UIBarButtonItem(title: "关闭", style: .plain, target: self, action: #selector(closeTapped))
        item.leftBarButtonItem?.accessibilityIdentifier = "shareExport.close"
        navigationBar.items = [item]
        view.addSubview(navigationBar)
        let scroll = UIScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.alwaysBounceVertical = true
        view.addSubview(scroll)
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)
        scopeControl.selectedSegmentIndex = 0
        formatControl.selectedSegmentIndex = 0
        scopeControl.accessibilityIdentifier = "shareExport.scope"
        scopeControl.addTarget(self, action: #selector(optionsChanged), for: .valueChanged)
        formatControl.accessibilityIdentifier = "shareExport.format"
        formatControl.addTarget(self, action: #selector(optionsChanged), for: .valueChanged)
        hintLabel.font = .preferredFont(forTextStyle: .footnote)
        hintLabel.textColor = .secondaryLabel
        hintLabel.numberOfLines = 0
        statusLabel.font = .preferredFont(forTextStyle: .subheadline)
        statusLabel.textColor = .secondaryLabel
        statusLabel.numberOfLines = 0
        statusLabel.accessibilityIdentifier = "shareExport.status"
        statusLabel.accessibilityTraits = .updatesFrequently
        configureSecondary(stopButton, title: "停止生成", identifier: "shareExport.stop", action: #selector(stopTapped))
        stopButton.isHidden = true
        configureSecondary(retryButton, title: "重试", identifier: "shareExport.retry", action: #selector(retryTapped))
        retryButton.isHidden = true
        configureDeliveryRow(saveRow, title: "保存到文件", subtitle: "使用“文件”App 选择位置",
                             symbol: "folder", identifier: "shareExport.save", action: #selector(saveTapped))
        configureDeliveryRow(shareRow, title: "分享", subtitle: "系统分享面板发送文件",
                             symbol: "square.and.arrow.up", identifier: "shareExport.share", action: #selector(shareTapped))
        for element in [sectionLabel("范围"), scopeControl, sectionLabel("格式"), formatControl,
                        hintLabel, sectionLabel("去向"), saveRow, shareRow, statusLabel,
                        stopButton, retryButton] {
            stack.addArrangedSubview(element)
        }
        NSLayoutConstraint.activate([
            navigationBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            navigationBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            navigationBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: navigationBar.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -24),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -20),
            stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -40)
        ])
    }
    private func sectionLabel(_ text: String) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = .preferredFont(forTextStyle: .headline)
        return label
    }
    private func configureSecondary(_ button: UIButton, title: String, identifier: String, action: Selector) {
        var config = UIButton.Configuration.bordered()
        config.title = title
        config.cornerStyle = .medium
        button.configuration = config
        button.accessibilityIdentifier = identifier
        button.addTarget(self, action: action, for: .touchUpInside)
    }
    private func configureDeliveryRow(_ button: UIButton, title: String, subtitle: String,
                                      symbol: String, identifier: String, action: Selector) {
        var config = UIButton.Configuration.plain()
        config.title = title
        config.subtitle = subtitle
        config.image = UIImage(systemName: symbol)
        config.imagePadding = 12
        config.titleAlignment = .leading
        config.contentInsets = NSDirectionalEdgeInsets(top: 14, leading: 14, bottom: 14, trailing: 14)
        config.background.backgroundColor = .secondarySystemBackground
        config.background.cornerRadius = 12
        config.subtitleTextAttributesTransformer = UIConfigurationTextAttributesTransformer {
            var out = $0
            out.font = .preferredFont(forTextStyle: .footnote)
            out.foregroundColor = .secondaryLabel
            return out
        }
        button.configuration = config
        button.contentHorizontalAlignment = .leading
        button.accessibilityIdentifier = identifier
        button.addTarget(self, action: action, for: .touchUpInside)
    }
    private var selectedFormat: Format {
        formatControl.selectedSegmentIndex == 1 ? .html : .markdown
    }
    private var selectedScope: Scope {
        scopeControl.selectedSegmentIndex == 1 ? .allPosts : .firstPost
    }
    @objc private func optionsChanged() {
        updateHints()
        guard !busy else { return }
        retryButton.isHidden = true
        statusLabel.textColor = .secondaryLabel
        statusLabel.text = cachedFile() == nil
            ? "选项已更新，保存或分享时会重新生成文件。"
            : "当前选项已有生成文件，保存或分享会直接使用。"
    }
    private func updateHints() {
        var lines = [selectedFormat == .markdown
            ? "Markdown：帖子原文，纯文本，文件体积小。"
            : "HTML：保留论坛排版与图片链接，可用浏览器打开。"]
        if selectedFormat == .markdown, selectedScope == .allPosts,
           topic.postIDs.count > Self.maxMarkdownPosts {
            lines.append("Markdown 最多导出前 \(Self.maxMarkdownPosts) 条帖子（共 \(topic.postIDs.count) 条）；完整主题请用 HTML。")
        }
        hintLabel.text = lines.joined(separator: "\n")
    }
    @objc private func saveTapped() { ensureAndDeliver(.save) }
    @objc private func shareTapped() { ensureAndDeliver(.share) }
    func resumeAfterAuthentication() { ensureAndDeliver(lastDelivery) }
    @objc private func retryTapped() {
        guard !busy else { return }
        ensureAndDeliver(lastDelivery)
    }
    @objc private func stopTapped() {
        guard busy else { return }
        stopWork()
        setBusy(false)
        statusLabel.text = "已停止生成，选项已保留，可重试。"
        retryButton.isHidden = false
    }
    @objc private func closeTapped() {
        stopWork()
        dismiss(animated: true)
    }
    private func ensureAndDeliver(_ delivery: Delivery) {
        guard !busy, presentedViewController == nil else { return }
        lastDelivery = delivery
        let format = selectedFormat
        let scope = selectedScope
        let key = cacheKey(format: format, scope: scope)
        if let cached = cachedFile(for: key) {
            showReady(cached)
            deliver(delivery, file: cached.url)
            return
        }
        start(message: "正在加载帖子…") { [weak self] id in
            guard let self = self else { throw CancellationError() }
            return try await self.generate(format: format, scope: scope, id: id)
        } onSuccess: { [weak self] cached in
            guard let self = self else { return }
            self.cachedFiles[key] = cached
            self.showReady(cached)
            self.deliver(delivery, file: cached.url)
        }
    }
    private func generate(format: Format, scope: Scope, id: UUID) async throws -> CachedFile {
        updateStatus("正在加载帖子…")
        let posts = try await client.posts(topic: topic, all: scope == .allPosts, markdown: format == .markdown)
        try ensureActive(id)
        let text: String
        if format == .markdown {
            updateStatus("正在获取 Markdown 原文…")
            text = try await client.markdown(topic: topic, posts: posts)
        } else {
            updateStatus("正在生成 HTML…")
            text = client.html(topic: topic, posts: posts)
        }
        try ensureActive(id)
        updateStatus("正在写入文件…")
        let file = directory.appendingPathComponent(filename(format: format, scope: scope))
        try text.write(to: file, atomically: true, encoding: .utf8)
        try ensureActive(id)
        return CachedFile(url: file, postCount: posts.count)
    }

    private func start(message: String, operation: @escaping (UUID) async throws -> CachedFile,
                       onSuccess: @escaping (CachedFile) -> Void) {
        guard work == nil else { return }
        generationID = UUID()
        let id = generationID
        setBusy(true, message: message)
        work = Task { [weak self] in
            guard let self = self else { return }
            do {
                let result = try await operation(id)
                guard self.generationID == id else { return }
                self.setBusy(false)
                onSuccess(result)
            } catch {
                guard self.generationID == id else { return }
                self.setBusy(false)
                self.handle(error)
            }
        }
    }

    private func setBusy(_ value: Bool, message: String = "") {
        busy = value
        formatControl.isEnabled = !value
        scopeControl.isEnabled = !value
        saveRow.isEnabled = !value
        shareRow.isEnabled = !value
        stopButton.isHidden = !value
        retryButton.isHidden = value
        if value { updateStatus(message) } else { work = nil }
    }

    private func showReady(_ cached: CachedFile) {
        let base = selectedFormat == .markdown ? "Markdown" : "HTML"
        let limited = selectedFormat == .markdown && selectedScope == .allPosts && topic.postIDs.count > Self.maxMarkdownPosts
        statusLabel.textColor = .secondaryLabel
        statusLabel.text = "已生成 \(base) 文件，包含 \(cached.postCount) 条帖子\(limited ? "（仅前 \(Self.maxMarkdownPosts) 条）" : "")。可保存到文件或分享。"
        retryButton.isHidden = true
    }

    private func handle(_ error: Error) {
        if error is CancellationError {
            statusLabel.textColor = .secondaryLabel
            statusLabel.text = "已停止生成，选项已保留，可重试。"
            retryButton.isHidden = false
            return
        }
        if let forum = error as? ForumShareError, forum.requiresAuthentication {
            // 先取消任务并保留重试，再交给父 dismiss 并展开验证；不在本页弹二次确认。
            stopWork()
            statusLabel.textColor = .systemOrange
            statusLabel.text = forum.errorDescription ?? "需要验证或登录后才能导出。"
            retryButton.isHidden = false
            onAuthenticationRequired()
            return
        }
        let message = (error as? ForumShareError)?.errorDescription
            ?? (error as? LocalizedError)?.errorDescription
            ?? error.localizedDescription
        statusLabel.textColor = .systemRed
        statusLabel.text = "导出失败：\(message)"
        retryButton.isHidden = false
    }

    private func deliver(_ delivery: Delivery, file: URL) {
        guard presentedViewController == nil else { return }
        switch delivery {
        case .save:
            let picker = UIDocumentPickerViewController(forExporting: [file], asCopy: true)
            picker.delegate = self
            picker.shouldShowFileExtensions = true
            picker.view.accessibilityIdentifier = "shareExport.documentPicker"
            present(picker, animated: true)
        case .share:
            let activity = UIActivityViewController(activityItems: [file], applicationActivities: nil)
            activity.view.accessibilityIdentifier = "shareExport.activity"
            if let popover = activity.popoverPresentationController {
                popover.sourceView = shareRow
                popover.sourceRect = shareRow.bounds
            }
            activity.completionWithItemsHandler = { [weak self] _, completed, _, error in
                Task { @MainActor in
                    guard let self = self else { return }
                    self.statusLabel.textColor = error == nil ? .secondaryLabel : .systemRed
                    if let error = error {
                        self.statusLabel.text = "分享失败：\(error.localizedDescription)。文件仍保留，可重试。"
                    } else if completed {
                        self.statusLabel.text = "分享已完成，文件仍保留，可再次保存或分享。"
                    } else {
                        self.statusLabel.text = "已取消系统分享，文件仍保留。"
                    }
                }
            }
            present(activity, animated: true)
        }
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        statusLabel.textColor = .secondaryLabel
        statusLabel.text = "已取消保存，生成的文件仍保留，可再次保存或分享。"
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        statusLabel.textColor = .secondaryLabel
        statusLabel.text = "已保存 \(urls.count) 个文件到所选位置，生成的文件仍保留在扩展内。"
    }

    private func cacheKey(format: Format, scope: Scope) -> String {
        "\(format.rawValue)-\(scope.rawValue)"
    }

    private func cachedFile(for key: String? = nil) -> CachedFile? {
        guard let cached = cachedFiles[key ?? cacheKey(format: selectedFormat, scope: selectedScope)],
              FileManager.default.fileExists(atPath: cached.url.path) else { return nil }
        return cached
    }

    private func filename(format: Format, scope: Scope) -> String {
        let scopeTag = scope == .allPosts ? "全部" : "主帖"
        return safeFilename(topic.title) + "-" + scopeTag + (format == .markdown ? ".md" : ".html")
    }

    private func safeFilename(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:?%*|\"<>\n\r")
        let result = name.components(separatedBy: invalid).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? "FluxDO文章" : String(result.prefix(60))
    }

    private func updateStatus(_ message: String) {
        statusLabel.textColor = .secondaryLabel
        statusLabel.text = message
    }

    private func ensureActive(_ id: UUID) throws {
        guard generationID == id else { throw CancellationError() }
        try Task.checkCancellation()
    }

    private func stopWork() {
        generationID = UUID()
        work?.cancel()
        work = nil
    }
}

private extension ForumShareError {
    /// 需要用户到扩展网页完成登录/验证的错误。
    var requiresAuthentication: Bool {
        switch self {
        case .loginRequired, .cloudflare, .accessDenied:
            return true
        default:
            return false
        }
    }
}
