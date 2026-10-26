import UIKit
import ImageIO

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = HarnessViewController()
        window.makeKeyAndVisible()
        self.window = window
        return true
    }
}

/// 离线 UI 回归入口：不启动 Flutter，也不访问论坛网络。
final class HarnessViewController: UIViewController {
    private let directory = OfflineFixtures.directory
    private let client = OfflineFixtures.client

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        view.accessibilityIdentifier = "harness.root"

        let title = UILabel()
        title.text = "FluxDO 分享 UI 离线回归"
        title.font = .preferredFont(forTextStyle: .title2)
        title.numberOfLines = 0
        title.textAlignment = .center

        let subtitle = UILabel()
        subtitle.text = "固定长帖与本地图片，仅验证分享扩展的 UIKit 页面。"
        subtitle.font = .preferredFont(forTextStyle: .footnote)
        subtitle.textColor = .secondaryLabel
        subtitle.numberOfLines = 0
        subtitle.textAlignment = .center

        let imageButton = makeButton(title: "图片分享",
                                     identifier: "harness.shareImage",
                                     action: #selector(showImagePreview))
        let exportButton = makeButton(title: "导出文章",
                                      identifier: "harness.export",
                                      action: #selector(showExport))

        let longImageButton = makeButton(title: "验证完整长图", identifier: "harness.longImage", action: #selector(checkLongImage))
        let stack = UIStackView(arrangedSubviews: [title, subtitle, imageButton, exportButton, longImageButton])
        stack.axis = .vertical
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerYAnchor),
            stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -28)
        ])
    }

    private func makeButton(title: String, identifier: String, action: Selector) -> UIButton {
        var configuration = UIButton.Configuration.filled()
        configuration.title = title
        configuration.cornerStyle = .large
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 14, leading: 20, bottom: 14, trailing: 20)
        let button = UIButton(configuration: configuration)
        button.accessibilityIdentifier = identifier
        button.addTarget(self, action: action, for: .touchUpInside)
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: 52).isActive = true
        return button
    }

    @objc private func checkLongImage() {
        present(LongImageCheckController(), animated: true)
    }

    @objc private func showImagePreview() {
        let controller = ShareImagePreviewController(
            topic: OfflineFixtures.topic,
            post: OfflineFixtures.topic.posts[0],
            directory: directory,
            imageLoader: OfflineFixtures.imageLoader,
            onAuthenticationRequired: {}
        )
        present(controller, animated: true)
    }

    @objc private func showExport() {
        let controller = ShareExportViewController(
            topic: OfflineFixtures.topic,
            client: client,
            directory: directory,
            onAuthenticationRequired: {}
        )
        present(controller, animated: true)
    }
}

/// 固定离线数据：40 段正文、代码块、表格、本地 PNG，以及末尾正文标记。
@MainActor
enum OfflineFixtures {
    static let host = "linux.do"
    static let topicID = 4242
    static let title = "离线长帖 UI 回归测试"
    static let endMarker = "OFFLINE_END_MARKER"
    static let postCount = 40

    static let topic: SharedTopic = makeTopic()
    static let directory: URL = makeDirectory()
    static let client: ForumShareClient = makeClient()
    static let imageLoader: ForumShareClient.Loader = makeImageLoader()

    private static let topicJSON: Data = makeTopicJSON()
    private static let imageData: Data = makePNG()

    private static func makeTopic() -> SharedTopic {
        let main = SharedPost(id: 10_001, postNumber: 1, username: "offline_author", cooked: makeMainHTML())
        var posts = [main]
        for number in 2...postCount {
            posts.append(SharedPost(
                id: 10_000 + number,
                postNumber: number,
                username: "offline_user_\(number)",
                cooked: "<p>第 \(number) 楼：离线重复回复，用于验证全部楼层导出。</p>"
            ))
        }
        return SharedTopic(
            id: topicID,
            title: title,
            slug: "offline-ui-regression",
            posts: posts,
            postIDs: posts.map(\.id),
            url: URL(string: "https://\(host)/t/\(topicID)")!
        )
    }

    private static func makeMainHTML() -> String {
        var sections: [String] = []
        for index in 1...postCount {
            sections.append("""
            <section>
              <h2>离线段落 \(index)/\(postCount)</h2>
              <p>这是第 \(index) 段重复正文，用来覆盖长图分片、主题切换、保存与系统分享，不访问任何论坛网络。</p>
              <pre><code>let offlineSegment = \(index)
            print("offline-segment-\(index)")</code></pre>
              <table>
                <thead><tr><th>字段</th><th>内容</th></tr></thead>
                <tbody><tr><td>段号</td><td>\(index)</td></tr><tr><td>来源</td><td>离线固定数据</td></tr></tbody>
              </table>
              <p><img src="https://\(host)/offline.png" alt="离线图片 \(index)" width="8" height="8"></p>
            </section>
            """)
        }
        sections.append("<p id=\"offline-end\">\(endMarker)</p>")
        return sections.joined(separator: "\n")
    }

    private static func makeRaw(for post: SharedPost) -> String {
        guard post.postNumber == 1 else {
            return "第 \(post.postNumber) 楼：离线重复回复，用于验证全部楼层导出。"
        }
        var lines = ["# \(title)"]
        for index in 1...postCount {
            lines.append("第 \(index) 段：离线重复正文，包含 `offline-segment-\(index)` 代码标记。")
            if index == postCount {
                lines.append("```swift\nprint(\"\(endMarker)\")\n```")
            }
        }
        lines.append(endMarker)
        return lines.joined(separator: "\n\n")
    }

    private static func makeTopicJSON() -> Data {
        let values: [[String: Any]] = topic.posts.map {
            [
                "id": $0.id,
                "topic_id": topicID,
                "post_number": $0.postNumber,
                "username": $0.username,
                "cooked": $0.cooked,
                "raw": makeRaw(for: $0)
            ]
        }
        let object: [String: Any] = [
            "id": topicID,
            "title": title,
            "slug": "offline-ui-regression",
            "post_stream": [
                "stream": topic.postIDs,
                "posts": values
            ]
        ]
        return (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
    }

    private static func postJSON(for id: Int) -> Data {
        guard let post = topic.posts.first(where: { $0.id == id }) else {
            return Data("{\"error_type\":\"not_found\"}".utf8)
        }
        let object: [String: Any] = [
            "id": post.id,
            "topic_id": topicID,
            "post_number": post.postNumber,
            "username": post.username,
            "cooked": post.cooked,
            "raw": makeRaw(for: post)
        ]
        return (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
    }

    private static func makeClient() -> ForumShareClient {
        let link = SharedTopicLink(url: topic.url, host: host, topicID: topicID, postNumber: nil)
        let loader: ForumShareClient.Loader = { url in
            let path = url.path
            let data: Data
            let name = (path as NSString).lastPathComponent
            if path.hasPrefix("/posts/"), let id = Int(name.split(separator: ".").first ?? "") {
                data = postJSON(for: id)
            } else if path.hasPrefix("/t/") {
                data = topicJSON
            } else {
                data = postJSON(for: topic.posts[0].id)
            }
            return (data, response(url: url, contentType: "application/json"))
        }
        return ForumShareClient(link: link, loader: loader)
    }

    private static func makeImageLoader() -> ForumShareClient.Loader {
        let data = imageData
        return { url in (data, response(url: url, contentType: "image/png")) }
    }

    private static func makePNG() -> Data {
        let size = CGSize(width: 8, height: 8)
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            UIColor.white.setFill()
            context.fill(CGRect(x: 2, y: 2, width: 4, height: 4))
        }
        return image.pngData() ?? Data()
    }

    private static func makeDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FluxDOShareHarness-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        return directory
    }

    private static func response(url: URL, contentType: String) -> HTTPURLResponse {
        HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": contentType]
        )!
    }
}

/// 直接检查生产 WebKit 截图链路的单张 PNG 尺寸、首尾像素与跨片边界。
@MainActor
private final class LongImageCheckController: UIViewController {
    private let renderer = ShareImageRenderer()
    private let result = UILabel()
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        view.backgroundColor = .white
        result.numberOfLines = 0
        result.frame = CGRect(x: 20, y: 50, width: 320, height: 100)
        result.accessibilityIdentifier = "harness.longImage.result"
        view.addSubview(result)
        Task {
            do {
                let html = """
                <html id="share-card"><head><meta name="viewport" content="width=device-width,initial-scale=1">
                <style>html,body{margin:0;padding:0;width:375px}div{height:2500px}</style></head>
                <body><div style="background:#ff0000"></div><div style="background:#0000ff"></div></body></html>
                """
                try await renderer.prepare(html: html, host: "linux.do", container: view)
                let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: root) }
                let file = try await renderer.capture(to: root.appendingPathComponent("whole.png")) { _ in }
                guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
                      let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
                      image.width == 750, image.height == 10000 else { throw CheckError.failed }
                func sample(_ y: Int) throws -> [UInt8] {
                    guard let crop = image.cropping(to: CGRect(x: 375, y: y, width: 1, height: 1)) else { throw CheckError.failed }
                    var bytes = [UInt8](repeating: 0, count: 4)
                    let okay = bytes.withUnsafeMutableBytes { raw -> Bool in
                        guard let context = CGContext(data: raw.baseAddress, width: 1, height: 1, bitsPerComponent: 8,
                            bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
                        context.draw(crop, in: CGRect(x: 0, y: 0, width: 1, height: 1))
                        return true
                    }
                    guard okay else { throw CheckError.failed }
                    return Array(bytes.prefix(3))
                }
                for y in [100, 1999, 2000, 3999, 4000, 4999] {
                    guard try sample(y) == [255, 0, 0] else { throw CheckError.failed }
                }
                for y in [5000, 5999, 6000, 7999, 8000, 9899] {
                    guard try sample(y) == [0, 0, 255] else { throw CheckError.failed }
                }
                renderer.cancel()
                result.text = "完整长图校验通过：750×10000，首尾像素与跨片边界完整"
                view.bringSubviewToFront(result)
            } catch {
                renderer.cancel()
                result.text = "完整长图校验失败：\(error.localizedDescription)"
                view.bringSubviewToFront(result)
            }
        }
    }
    private enum CheckError: Error { case failed }
}
