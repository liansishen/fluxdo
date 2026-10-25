import UIKit
import UniformTypeIdentifiers
import Photos
import ImageIO

@MainActor
final class ShareViewController: UIViewController, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout, UIDocumentPickerDelegate, UIAdaptivePresentationControllerDelegate {
    private var work: Task<Void, Never>?
    private var operationID = UUID()
    private var closed = false
    private var providerProgress: [Progress] = []
    private var client: ForumShareClient?
    private var topic: SharedTopic?
    private var link: SharedTopicLink?
    private var renderer: ShareImageRenderer?
    private var output: [URL] = []
    private var outputIsImages = false
    private var workingDirectory: URL?
    private var previousDirectories: [URL] = []
    private var retryAction: (() -> Void)?

    private let titleLabel = UILabel()
    private let statusLabel = UILabel()
    private let sessionHint = UILabel()
    private let imageButton = UIButton(type: .system)
    private let exportButton = UIButton(type: .system)
    private let retryButton = UIButton(type: .system)
    private let cancelWorkButton = UIButton(type: .system)
    private let shareButton = UIButton(type: .system)
    private let saveFilesButton = UIButton(type: .system)
    private let savePhotosButton = UIButton(type: .system)
    private let formatControl = UISegmentedControl(items: ["Markdown", "HTML"])
    private let scopeControl = UISegmentedControl(items: ["仅主帖", "全部楼层"])
    private let scopeHint = UILabel()
    private let pageLabel = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let renderContainer = UIView()
    private var preview: UICollectionView!
    private var previewHeight: NSLayoutConstraint!
    private var navigationBar: UINavigationBar!
    private var doneItem: UIBarButtonItem!

    override func viewDidLoad() {
        super.viewDidLoad()
        configureUI()
        beginLoading()
    }

    private func configureUI() {
        view.backgroundColor = .systemBackground
        preferredContentSize = CGSize(width: 480, height: 760)
        navigationBar = UINavigationBar()
        navigationBar.translatesAutoresizingMaskIntoConstraints = false
        let item = UINavigationItem(title: "FluxDO 分享")
        item.leftBarButtonItem = UIBarButtonItem(title: "取消", style: .plain, target: self, action: #selector(closeCancelled))
        doneItem = UIBarButtonItem(title: "完成", style: .done, target: self, action: #selector(closeCompleted))
        item.rightBarButtonItem = doneItem
        navigationBar.items = [item]
        view.addSubview(navigationBar)

        let scroll = UIScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.backgroundColor = .systemBackground
        view.addSubview(scroll)
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 14
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
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -24),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -20),
            stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -40)
        ])
        titleLabel.font = .preferredFont(forTextStyle: .title2)
        titleLabel.numberOfLines = 0
        titleLabel.text = "正在读取分享链接…"
        stack.addArrangedSubview(titleLabel)
        statusLabel.font = .preferredFont(forTextStyle: .subheadline)
        statusLabel.textColor = .secondaryLabel
        statusLabel.numberOfLines = 0
        statusLabel.accessibilityTraits = .updatesFrequently
        stack.addArrangedSubview(statusLabel)
        sessionHint.font = .preferredFont(forTextStyle: .footnote)
        sessionHint.textColor = .secondaryLabel
        sessionHint.numberOfLines = 0
        sessionHint.isHidden = true
        stack.addArrangedSubview(sessionHint)
        stack.addArrangedSubview(spinner)

        let pictureHint = UILabel()
        pictureHint.text = "分享图片：包含主帖标题、作者、来源及完整正文。长文会自动分为多张 PNG，不会截断。"
        pictureHint.numberOfLines = 0
        pictureHint.font = .preferredFont(forTextStyle: .subheadline)
        stack.addArrangedSubview(pictureHint)
        configureButton(imageButton, title: "生成分享图片", action: #selector(generateImages))
        stack.addArrangedSubview(imageButton)
        let separator = UIView()
        separator.backgroundColor = .separator
        separator.heightAnchor.constraint(equalToConstant: 1).isActive = true
        stack.addArrangedSubview(separator)
        let exportTitle = UILabel()
        exportTitle.text = "导出文章"
        exportTitle.font = .preferredFont(forTextStyle: .headline)
        stack.addArrangedSubview(exportTitle)
        formatControl.selectedSegmentIndex = 0
        scopeControl.selectedSegmentIndex = 0
        formatControl.addTarget(self, action: #selector(updateScopeHint), for: .valueChanged)
        scopeControl.addTarget(self, action: #selector(updateScopeHint), for: .valueChanged)
        stack.addArrangedSubview(formatControl)
        stack.addArrangedSubview(scopeControl)
        scopeHint.font = .preferredFont(forTextStyle: .footnote)
        scopeHint.textColor = .secondaryLabel
        scopeHint.numberOfLines = 0
        stack.addArrangedSubview(scopeHint)
        updateScopeHint()
        configureButton(exportButton, title: "生成文章文件", action: #selector(generateExport))
        stack.addArrangedSubview(exportButton)
        configureButton(cancelWorkButton, title: "停止当前操作", action: #selector(cancelCurrentWork))
        stack.addArrangedSubview(cancelWorkButton)
        configureButton(retryButton, title: "重试", action: #selector(retry))
        stack.addArrangedSubview(retryButton)
        retryButton.isHidden = true
        cancelWorkButton.isHidden = true

        let layout = UICollectionViewFlowLayout()
        layout.scrollDirection = .horizontal
        layout.minimumLineSpacing = 0
        layout.minimumInteritemSpacing = 0
        preview = UICollectionView(frame: .zero, collectionViewLayout: layout)
        preview.backgroundColor = .secondarySystemBackground
        preview.isPagingEnabled = true
        preview.showsHorizontalScrollIndicator = true
        preview.register(SharePreviewCell.self, forCellWithReuseIdentifier: "image")
        preview.dataSource = self
        preview.delegate = self
        previewHeight = preview.heightAnchor.constraint(equalToConstant: 0)
        previewHeight.isActive = true
        stack.addArrangedSubview(preview)
        pageLabel.font = .preferredFont(forTextStyle: .footnote)
        pageLabel.numberOfLines = 0
        pageLabel.isHidden = true
        stack.addArrangedSubview(pageLabel)
        configureButton(saveFilesButton, title: "保存到文件", action: #selector(saveFiles))
        configureButton(savePhotosButton, title: "保存全部图片到相册", action: #selector(savePhotos))
        configureButton(shareButton, title: "系统分享", action: #selector(shareOutput))
        [saveFilesButton, savePhotosButton, shareButton].forEach {
            $0.isHidden = true
            stack.addArrangedSubview($0)
        }
        renderContainer.translatesAutoresizingMaskIntoConstraints = false
        renderContainer.clipsToBounds = true
        renderContainer.isUserInteractionEnabled = false
        view.insertSubview(renderContainer, at: 0)
        NSLayoutConstraint.activate([
            renderContainer.topAnchor.constraint(equalTo: view.topAnchor),
            renderContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            renderContainer.widthAnchor.constraint(equalTo: view.widthAnchor),
            renderContainer.heightAnchor.constraint(equalToConstant: 1000)
        ])
    }

    private func configureButton(_ button: UIButton, title: String, action: Selector) {
        var configuration = UIButton.Configuration.tinted()
        configuration.title = title
        configuration.cornerStyle = .medium
        button.configuration = configuration
        button.addTarget(self, action: action, for: .touchUpInside)
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
    }

    @objc private func updateScopeHint() {
        if formatControl.selectedSegmentIndex == 0 {
            scopeHint.text = "Markdown 最多导出 10 条帖子；选择全部楼层时仅包含前 10 条。需要完整长帖请选 HTML。"
        } else {
            scopeHint.text = "HTML 选择全部楼层会分批读取完整主题，任一批次失败将明确报错，不会导出残缺文章。"
        }
    }

    private func beginLoading() {
        start(message: "正在读取链接并加载主题…", retry: { [weak self] in self?.beginLoading() }) { [weak self] id in
            guard let self = self else { return }
            let link = try await self.receiveLink()
            try self.ensureActive(id)
            do {
                _ = try ShareSessionStore.readSession(host: link.host)
                self.sessionHint.isHidden = true
            } catch {
                let message: String
                if let storeError = error as? ShareSessionStore.StoreError {
                    switch storeError {
                    case .unavailableGroup:
                        message = "SideStore 共享组权限不可用，无法读取 FluxDO 分享会话；请检查主应用与分享扩展的 App Groups 签名权限。"
                    case .missingSession:
                        message = "尚未同步 \(link.host) 的分享会话，请打开 FluxDO，切换至该站点并完成登录与会话同步后重新分享。"
                    case .expiredSession:
                        message = "\(link.host) 的分享会话已过期，请打开 FluxDO，切换至该站点并重新登录、同步会话后重新分享。"
                    case .invalidSession:
                        message = "\(link.host) 的分享会话已损坏或格式无效，请打开 FluxDO，切换至该站点并重新同步会话后重新分享。"
                    case .fileOperation(let code):
                        message = "无法读取 \(link.host) 的分享会话文件（诊断码：FILE_OPERATION_\(code)），请解锁设备后重试，或打开 FluxDO 重新同步会话。"
                    case .unsupportedHost:
                        message = "该站点不支持 FluxDO 分享会话（诊断码：UNSUPPORTED_HOST）。"
                    }
                } else {
                    // 仅展示固定诊断码，不泄露底层路径或认证信息。
                    message = "无法读取 FluxDO 分享会话（诊断码：SESSION_READ_FAILED）。"
                }
                self.sessionHint.text = "\(message)当前仅尝试匿名加载公开帖子。"
                self.sessionHint.isHidden = false
            }
            let client = ForumShareClient(link: link)
            let topic = try await client.loadTopic()
            try self.ensureActive(id)
            self.link = link
            self.client = client
            self.topic = topic
            self.titleLabel.text = topic.title
            self.statusLabel.text = "\(link.host) · 已加载主帖。请选择生成图片或导出文章。"
        }
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
        guard let client = client, let topic = topic, let link = link else { return }
        start(message: "正在准备主帖图片…", retry: { [weak self] in self?.generateImages() }) { [weak self] id in
            guard let self = self else { return }
            let posts = try await client.posts(topic: topic, all: false, markdown: false)
            try self.ensureActive(id)
            let directory = try self.makeDirectory()
            let renderer = ShareImageRenderer()
            self.renderer = renderer
            let html = client.html(topic: topic, posts: posts, imageScheme: "fluxdo-share-image")
            let files = try await renderer.render(html: html, host: link.host, directory: directory, container: self.renderContainer) { [weak self] message in
                guard let self = self, !self.closed, self.operationID == id else { return }
                self.statusLabel.text = message
            }
            try self.ensureActive(id)
            self.renderer = nil
            self.showOutput(files, images: true)
            self.statusLabel.text = "已生成 \(files.count) 张 PNG，覆盖完整主帖正文。可左右滑动预览，保存或分享时将包含全部 \(files.count) 张。"
        }
    }

    @objc private func generateExport() {
        guard let client = client, let topic = topic else { return }
        let all = scopeControl.selectedSegmentIndex == 1
        let markdown = formatControl.selectedSegmentIndex == 0
        start(message: all && !markdown ? "正在分批加载全部楼层…" : "正在准备文章…", retry: { [weak self] in self?.generateExport() }) { [weak self] id in
            guard let self = self else { return }
            let posts = try await client.posts(topic: topic, all: all, markdown: markdown)
            try self.ensureActive(id)
            let text: String
            if markdown { text = try await client.markdown(topic: topic, posts: posts) }
            else { text = client.html(topic: topic, posts: posts) }
            try self.ensureActive(id)
            let directory = try self.makeDirectory()
            let file = directory.appendingPathComponent(self.safeFilename(topic.title) + (markdown ? ".md" : ".html"))
            try text.write(to: file, atomically: true, encoding: .utf8)
            try self.ensureActive(id)
            self.showOutput([file], images: false)
            self.statusLabel.text = "已生成 \(markdown ? "Markdown" : "HTML") 文件，包含 \(posts.count) 条帖子。\(markdown && all ? "Markdown 最多包含前 10 条；完整主题请使用 HTML。" : "")"
        }
    }

    private func start(message: String, retry: @escaping () -> Void,
                       operation: @escaping (UUID) async throws -> Void) {
        guard !closed else { return }
        stopWork()
        let id = UUID()
        operationID = id
        retryAction = retry
        setBusy(true)
        statusLabel.text = message
        retryButton.isHidden = true
        work = Task { [weak self] in
            do {
                try await operation(id)
                guard let self = self, !self.closed, self.operationID == id else { return }
                self.setBusy(false)
                self.work = nil
                self.providerProgress.removeAll()
            } catch {
                guard let self = self, !self.closed, self.operationID == id else { return }
                self.renderer?.cancel()
                self.renderer = nil
                self.setBusy(false)
                self.work = nil
                self.providerProgress.removeAll()
                if error is CancellationError {
                    self.statusLabel.text = "已停止操作，可重试。"
                } else {
                    self.statusLabel.text = "\(error.localizedDescription)\n若提示未登录或 Cloudflare 验证，请先在 FluxDO 完成验证并同步会话，再重新分享；扩展不会打开登录页或主应用。"
                }
                self.retryButton.isHidden = false
            }
        }
    }

    private func ensureActive(_ id: UUID) throws {
        try Task.checkCancellation()
        if closed || id != operationID { throw CancellationError() }
    }

    private func setBusy(_ busy: Bool) {
        let ready = topic != nil && client != nil
        imageButton.isEnabled = !busy && ready
        exportButton.isEnabled = !busy && ready
        formatControl.isEnabled = !busy
        scopeControl.isEnabled = !busy
        shareButton.isEnabled = !busy
        saveFilesButton.isEnabled = !busy
        savePhotosButton.isEnabled = !busy
        cancelWorkButton.isHidden = !busy
        doneItem.isEnabled = !busy
        if busy { spinner.startAnimating() } else { spinner.stopAnimating() }
    }

    private func stopWork() {
        operationID = UUID()
        work?.cancel()
        work = nil
        renderer?.cancel()
        renderer = nil
        providerProgress.forEach { $0.cancel() }
        providerProgress.removeAll()
    }

    @objc private func cancelCurrentWork() {
        stopWork()
        setBusy(false)
        statusLabel.text = "已停止当前操作，扩展仍保持打开。"
        retryButton.isHidden = false
    }

    @objc private func retry() { retryAction?() }

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

    private func safeFilename(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:?%*|\"<>\n\r")
        let result = name.components(separatedBy: invalid).joined(separator: "-").trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? "FluxDO文章" : String(result.prefix(80))
    }

    private func showOutput(_ files: [URL], images: Bool) {
        output = files
        outputIsImages = images
        previewHeight.constant = images ? 320 : 0
        preview.isHidden = !images
        preview.reloadData()
        preview.setContentOffset(.zero, animated: false)
        pageLabel.isHidden = false
        pageLabel.text = images ? "第 1 / \(files.count) 张 · 左右滑动查看全部分片" : files.first?.lastPathComponent
        saveFilesButton.isHidden = false
        shareButton.isHidden = false
        savePhotosButton.isHidden = !images
        shareButton.configuration?.title = images ? "系统分享全部 \(files.count) 张图片" : "系统分享文章文件"
    }

    @objc private func shareOutput() {
        guard !closed, !output.isEmpty, presentedViewController == nil else { return }
        let activity = UIActivityViewController(activityItems: output, applicationActivities: nil)
        activity.popoverPresentationController?.sourceView = shareButton
        activity.popoverPresentationController?.sourceRect = shareButton.bounds
        activity.completionWithItemsHandler = { [weak self] _, completed, _, error in
            Task { @MainActor in
                guard let self = self, !self.closed else { return }
                if let error = error { self.statusLabel.text = "分享失败：\(error.localizedDescription)。文件仍保留，可重试。" }
                else { self.statusLabel.text = completed ? "分享已完成，文件仍可再次保存或分享。" : "已取消系统分享，文件仍保留，可继续操作。" }
            }
        }
        present(activity, animated: true)
    }

    @objc private func saveFiles() {
        guard !closed, !output.isEmpty, presentedViewController == nil else { return }
        let picker = UIDocumentPickerViewController(forExporting: output, asCopy: true)
        picker.delegate = self
        picker.shouldShowFileExtensions = true
        present(picker, animated: true)
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        guard !closed else { return }
        statusLabel.text = "已取消保存，文件仍保留，可重新保存或分享。"
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard !closed else { return }
        statusLabel.text = "已保存 \(urls.count) 个文件，可继续分享或点击完成。"
    }

    @objc private func savePhotos() {
        guard outputIsImages, !output.isEmpty else { return }
        let files = output
        start(message: "正在保存全部 \(files.count) 张图片到相册…", retry: { [weak self] in self?.savePhotos() }) { [weak self] id in
            guard let self = self else { return }
            let authorization = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            try self.ensureActive(id)
            guard authorization == .authorized || authorization == .limited else {
                throw ShareUIError.message("未获得添加照片权限。可选择保存到文件或系统分享。")
            }
            self.cancelWorkButton.isHidden = true
            self.statusLabel.text = "正在保存全部 \(files.count) 张图片；相册写入开始后无法撤回。"
            try await PHPhotoLibrary.shared().performChanges {
                for file in files { PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: file) }
            }
            try self.ensureActive(id)
            self.statusLabel.text = "已保存全部 \(files.count) 张图片到相册。"
        }
    }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        outputIsImages ? output.count : 0
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "image", for: indexPath) as! SharePreviewCell
        cell.show(output[indexPath.item])
        cell.accessibilityLabel = "第 \(indexPath.item + 1) 张，共 \(output.count) 张"
        return cell
    }

    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout,
                        sizeForItemAt indexPath: IndexPath) -> CGSize {
        CGSize(width: max(1, collectionView.bounds.width), height: 320)
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { updatePage(scrollView) }
    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { updatePage(scrollView) }
    }

    private func updatePage(_ scroll: UIScrollView) {
        guard scroll === preview, outputIsImages, !output.isEmpty else { return }
        let page = min(output.count, max(1, Int((scroll.contentOffset.x / max(1, scroll.bounds.width)).rounded()) + 1))
        pageLabel.text = "第 \(page) / \(output.count) 张 · 保存和分享均包含全部分片"
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        preview?.collectionViewLayout.invalidateLayout()
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
        let renderer = renderer
        Task { @MainActor in renderer?.cancel() }
    }

    @objc private func closeCancelled() { close(cancelled: true) }
    @objc private func closeCompleted() { close(cancelled: false) }

    private func close(cancelled: Bool) {
        guard !closed else { return }
        closed = true
        stopWork()
        let directories = previousDirectories + (workingDirectory.map { [$0] } ?? [])
        // 仅在扩展结束且系统确认交付后删除，系统分享/文件选择器取消不会触发清理。
        let cleanup: (Bool) -> Void = { _ in
            directories.forEach { try? FileManager.default.removeItem(at: $0) }
        }
        if cancelled {
            // cancelRequest 没有交付完成回调，保留临时文件由系统清理，避免接收方仍在读取。
            extensionContext?.cancelRequest(withError: NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError))
        } else {
            extensionContext?.completeRequest(returningItems: nil, completionHandler: cleanup)
        }
    }
}

private enum ShareUIError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let text): return text }
    }
}

private final class SharePreviewCell: UICollectionViewCell {
    private let imageView = UIImageView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        imageView.contentMode = .scaleAspectFit
        imageView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            imageView.topAnchor.constraint(equalTo: contentView.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        ])
        isAccessibilityElement = true
    }

    required init?(coder: NSCoder) { fatalError("不支持 storyboard") }

    override func prepareForReuse() {
        super.prepareForReuse()
        imageView.image = nil
    }

    func show(_ file: URL) {
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 1000,
                kCGImageSourceCreateThumbnailWithTransform: true
              ] as CFDictionary) else { return }
        imageView.image = UIImage(cgImage: thumbnail)
    }
}

/// 提供方取消不保证回调，因此主动结束等待，并忽略迟到或重复的回调。
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
