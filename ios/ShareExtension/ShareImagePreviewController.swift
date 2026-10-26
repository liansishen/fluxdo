import UIKit
import Photos

@MainActor
final class ShareImagePreviewController: UIViewController, UIAdaptivePresentationControllerDelegate {
    private let topic: SharedTopic
    private let post: SharedPost
    private let directory: URL
    private let imageLoader: ForumShareClient.Loader?
    private let onAuthenticationRequired: () -> Void
    private let renderer = ShareImageRenderer()
    private var work: Task<Void, Never>?
    private var themeWork: Task<Void, Never>?
    private var pendingDelivery: (() -> Void)?
    private var generation = UUID()
    private var selected: ShareImagePalette
    private var rendered: ShareImagePalette?
    private var cachedImage: (ShareImagePalette, URL)?
    private var ready = false
    private var busy = false
    private let previewContainer = UIView()
    private let status = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let saveButton = UIButton(type: .system)
    private let shareButton = UIButton(type: .system)
    private let retryButton = UIButton(type: .system)
    private let stopButton = UIButton(type: .system)
    private var themeButtons: [UIButton] = []

    init(topic: SharedTopic, post: SharedPost, directory: URL, imageLoader: ForumShareClient.Loader?,
         onAuthenticationRequired: @escaping () -> Void) {
        self.topic = topic
        self.post = post
        self.directory = directory
        self.imageLoader = imageLoader
        self.onAuthenticationRequired = onAuthenticationRequired
        selected = ShareImagePalette(rawValue: UserDefaults.standard.integer(forKey: "shareImageThemeIndex")) ?? .classic
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .pageSheet
    }

    required init?(coder: NSCoder) { fatalError("不支持从归档创建图片预览") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        if let sheet = sheetPresentationController {
            sheet.detents = [.large()]
            sheet.prefersGrabberVisible = true
        }
        let bar = UINavigationBar()
        let item = UINavigationItem(title: "分享图片")
        item.leftBarButtonItem = UIBarButtonItem(title: "关闭", style: .plain, target: self, action: #selector(close))
        item.leftBarButtonItem?.accessibilityIdentifier = "shareImage.close"
        bar.items = [item]
        let root = UIStackView()
        root.axis = .vertical
        root.spacing = 8
        root.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(root)
        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            root.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            root.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor)
        ])
        root.addArrangedSubview(bar)
        status.numberOfLines = 0
        status.textAlignment = .center
        status.font = .preferredFont(forTextStyle: .footnote)
        status.accessibilityIdentifier = "shareImage.status"
        let feedback = UIStackView(arrangedSubviews: [spinner, status])
        feedback.spacing = 8
        feedback.layoutMargins = UIEdgeInsets(top: 0, left: 16, bottom: 0, right: 16)
        feedback.isLayoutMarginsRelativeArrangement = true
        root.addArrangedSubview(feedback)
        previewContainer.clipsToBounds = true
        previewContainer.backgroundColor = .secondarySystemBackground
        root.addArrangedSubview(previewContainer)
        previewContainer.heightAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
        previewContainer.setContentHuggingPriority(.defaultLow, for: .vertical)

        let themeScroll = UIScrollView()
        themeScroll.accessibilityIdentifier = "shareImage.themes"
        themeScroll.showsHorizontalScrollIndicator = false
        themeScroll.heightAnchor.constraint(equalToConstant: 76).isActive = true
        let themes = UIStackView()
        themes.spacing = 10
        themes.translatesAutoresizingMaskIntoConstraints = false
        themeScroll.addSubview(themes)
        NSLayoutConstraint.activate([
            themes.leadingAnchor.constraint(equalTo: themeScroll.contentLayoutGuide.leadingAnchor, constant: 16),
            themes.trailingAnchor.constraint(equalTo: themeScroll.contentLayoutGuide.trailingAnchor, constant: -16),
            themes.topAnchor.constraint(equalTo: themeScroll.contentLayoutGuide.topAnchor, constant: 4),
            themes.bottomAnchor.constraint(equalTo: themeScroll.contentLayoutGuide.bottomAnchor, constant: -4),
            themes.heightAnchor.constraint(equalTo: themeScroll.frameLayoutGuide.heightAnchor, constant: -8)
        ])
        for palette in ShareImagePalette.allCases {
            let button = UIButton(type: .system)
            button.tag = palette.rawValue
            button.accessibilityIdentifier = "shareImage.theme." + palette.themeKey
            button.accessibilityLabel = palette.name
            button.widthAnchor.constraint(equalToConstant: 42).isActive = true
            button.addTarget(self, action: #selector(changeTheme(_:)), for: .touchUpInside)
            themeButtons.append(button)
            themes.addArrangedSubview(button)
        }
        root.addArrangedSubview(themeScroll)
        configure(saveButton, title: "保存到相册", symbol: "square.and.arrow.down", action: #selector(save))
        configure(shareButton, title: "分享", symbol: "square.and.arrow.up", action: #selector(shareImage))
        saveButton.accessibilityIdentifier = "shareImage.save"
        shareButton.accessibilityIdentifier = "shareImage.share"
        var filled = shareButton.configuration!
        filled.baseBackgroundColor = .systemOrange
        filled.baseForegroundColor = .white
        shareButton.configuration = filled
        let actions = UIStackView(arrangedSubviews: [saveButton, shareButton])
        actions.spacing = 12
        actions.distribution = .fillEqually
        actions.layoutMargins = UIEdgeInsets(top: 6, left: 16, bottom: 12, right: 16)
        actions.isLayoutMarginsRelativeArrangement = true
        root.addArrangedSubview(actions)
        configure(retryButton, title: "重试", symbol: "arrow.clockwise", action: #selector(retry))
        configure(stopButton, title: "停止当前操作", symbol: "stop.circle", action: #selector(stop))
        let recovery = UIStackView(arrangedSubviews: [retryButton, stopButton])
        recovery.distribution = .fillEqually
        root.addArrangedSubview(recovery)
        retryButton.isHidden = true
        stopButton.isHidden = true
        updateThemes()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        presentationController?.delegate = self
        if !ready && work == nil { prepare() }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutPreview()
    }

    private func layoutPreview() {
        guard let web = renderer.previewView, !busy else { return }
        let scale = min(1, max(1, previewContainer.bounds.width - 32) / 375)
        web.transform = .identity
        web.bounds = CGRect(x: 0, y: 0, width: 375, height: max(100, previewContainer.bounds.height / scale))
        web.center = CGPoint(x: previewContainer.bounds.midX, y: previewContainer.bounds.midY)
        web.transform = CGAffineTransform(scaleX: scale, y: scale)
    }

    private func configure(_ button: UIButton, title: String, symbol: String, action: Selector) {
        var configuration = UIButton.Configuration.tinted()
        configuration.title = title
        configuration.image = UIImage(systemName: symbol)
        configuration.imagePadding = 6
        configuration.cornerStyle = .capsule
        button.configuration = configuration
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        button.addTarget(self, action: action, for: .touchUpInside)
    }

    private func updateThemes() {
        for button in themeButtons {
            guard let palette = ShareImagePalette(rawValue: button.tag) else { continue }
            let swatch = UIGraphicsImageRenderer(size: CGSize(width: 36, height: 36)).image { context in
                let hex = palette.background.replacingOccurrences(of: "#", with: "")
                let value = UInt32(hex, radix: 16) ?? 0xffffff
                UIColor(red: CGFloat((value >> 16) & 255) / 255, green: CGFloat((value >> 8) & 255) / 255,
                        blue: CGFloat(value & 255) / 255, alpha: 1).setFill()
                context.cgContext.fillEllipse(in: CGRect(x: 1, y: 1, width: 34, height: 34))
                (palette == selected ? UIColor.systemOrange : UIColor.separator).setStroke()
                context.cgContext.setLineWidth(palette == selected ? 2.5 : 1)
                context.cgContext.strokeEllipse(in: CGRect(x: 1.5, y: 1.5, width: 33, height: 33))
            }
            var configuration = UIButton.Configuration.plain()
            configuration.image = swatch.withRenderingMode(.alwaysOriginal)
            configuration.title = palette.name
            configuration.imagePlacement = .top
            configuration.imagePadding = 4
            configuration.contentInsets = .zero
            configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
                var result = incoming
                result.font = .systemFont(ofSize: 10)
                return result
            }
            button.configuration = configuration
            button.accessibilityValue = palette == selected ? "已选择" : "未选择"
            button.isSelected = palette == selected
        }
    }

    private func prepare() {
        ready = false
        run(message: "正在加载图片预览…") { [weak self] in
            guard let self = self else { return }
            let theme = self.selected
            try await self.renderer.prepare(html: ShareImageDocument.html(topic: self.topic, post: self.post, palette: theme),
                                            host: self.topic.url.host ?? "", container: self.previewContainer,
                                            imageLoader: self.imageLoader)
            self.rendered = theme
            try await self.applyTheme()
            self.ready = true
            self.status.text = "完整长图预览 · 可上下滚动，切换配色实时更新"
        }
    }

    @objc private func changeTheme(_ button: UIButton) {
        guard let theme = ShareImagePalette(rawValue: button.tag), !busy else { return }
        selected = theme
        cachedImage = nil
        UserDefaults.standard.set(theme.rawValue, forKey: "shareImageThemeIndex")
        updateThemes()
        guard ready else { prepare(); return }
        guard themeWork == nil else { return }
        saveButton.isEnabled = false
        shareButton.isEnabled = false
        themeWork = Task { [weak self] in
            guard let self = self else { return }
            do {
                try await self.applyTheme()
                self.status.text = "配色已更新 · 完整长图预览"
            } catch {
                self.status.text = "配色更新失败，请重试。"
                self.retryButton.isHidden = false
            }
            self.themeWork = nil
            self.setBusy(self.busy)
        }
    }

    private func applyTheme() async throws {
        while rendered != selected {
            let target = selected
            try await renderer.selectTheme(target)
            try Task.checkCancellation()
            rendered = target
        }
    }

    private func imageFile() async throws -> URL {
        try await applyTheme()
        if let cached = cachedImage, cached.0 == selected, FileManager.default.fileExists(atPath: cached.1.path) { return cached.1 }
        let file = directory.appendingPathComponent("FluxDO-" + selected.themeKey + "-" + UUID().uuidString + ".png")
        let url = try await renderer.capture(to: file) { [weak self] text in self?.status.text = text }
        try Task.checkCancellation()
        cachedImage = (selected, url)
        return url
    }

    @objc private func save() {
        guard ready, !busy, themeWork == nil else { return }
        pendingDelivery = { [weak self] in self?.save() }
        run(message: "正在保存完整长图…") { [weak self] in
            guard let self = self else { return }
            let authorization = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            try Task.checkCancellation()
            guard authorization == .authorized || authorization == .limited else {
                throw ShareImageError.message("未获得添加照片权限，可使用分享按钮保存到文件。")
            }
            let url = try await self.imageFile()
            try Task.checkCancellation()
            self.stopButton.isHidden = true
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: url)
            }
            self.pendingDelivery = nil
            self.status.text = "已保存 1 张完整长图到相册"
        }
    }

    @objc private func shareImage() {
        guard ready, !busy, themeWork == nil else { return }
        pendingDelivery = { [weak self] in self?.shareImage() }
        run(message: "正在准备完整长图…") { [weak self] in
            guard let self = self else { return }
            let url = try await self.imageFile()
            try Task.checkCancellation()
            let activity = UIActivityViewController(activityItems: [url], applicationActivities: nil)
            activity.view.accessibilityIdentifier = "shareImage.activity"
            activity.popoverPresentationController?.sourceView = self.shareButton
            activity.popoverPresentationController?.sourceRect = self.shareButton.bounds
            activity.completionWithItemsHandler = { [weak self] _, completed, _, _ in
                Task { @MainActor in self?.status.text = completed ? "已分享完整长图" : "已取消分享，可继续调整配色" }
            }
            self.pendingDelivery = nil
            self.present(activity, animated: true)
            self.status.text = "已生成 1 张完整长图"
        }
    }

    private func run(message: String, operation: @escaping () async throws -> Void) {
        guard !busy else { return }
        let id = UUID()
        generation = id
        setBusy(true)
        status.text = message
        retryButton.isHidden = true
        work = Task { [weak self] in
            do {
                try await operation()
                guard let self = self, self.generation == id else { return }
                self.work = nil
                self.setBusy(false)
                self.layoutPreview()
                if let delivery = self.pendingDelivery {
                    self.pendingDelivery = nil
                    delivery()
                }
            } catch {
                guard let self = self, self.generation == id else { return }
                self.work = nil
                self.setBusy(false)
                if error is CancellationError { self.status.text = "已停止操作，可重试。" }
                else if let forum = error as? ForumShareError {
                    self.status.text = forum.localizedDescription
                    switch forum {
                    case .cloudflare, .loginRequired, .accessDenied:
                        self.ready = false
                        self.renderer.cancel()
                        self.onAuthenticationRequired()
                    default: break
                    }
                } else {
                    self.status.text = (error as? ShareImageError)?.errorDescription
                        ?? (error as? ShareLongImageWriterError)?.errorDescription ?? "图片生成失败，请重试。"
                }
                self.retryButton.isHidden = false
            }
        }
    }

    private func setBusy(_ value: Bool) {
        busy = value
        saveButton.isEnabled = !value && ready && themeWork == nil
        shareButton.isEnabled = !value && ready && themeWork == nil
        themeButtons.forEach { $0.isEnabled = !value }
        stopButton.isHidden = !value
        if value { spinner.startAnimating() } else { spinner.stopAnimating() }
    }

    func resumeAfterAuthentication() {
        if !ready && work == nil { prepare() }
    }

    @objc private func retry() {
        renderer.cancel()
        ready = false
        rendered = nil
        cachedImage = nil
        prepare()
    }

    @objc private func stop() {
        generation = UUID()
        work?.cancel()
        themeWork?.cancel()
        work = nil
        themeWork = nil
        renderer.cancel()
        ready = false
        setBusy(false)
        status.text = "已停止操作，可重试。"
        retryButton.isHidden = false
    }

    @objc private func close() { stop(); dismiss(animated: true) }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed || presentingViewController == nil { stop() }
    }

    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) { stop() }
}
