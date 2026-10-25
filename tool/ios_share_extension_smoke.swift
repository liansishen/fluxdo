import Foundation

/// 在 macOS CI 直接运行生产解析器和 HTML 导出器，不依赖主应用或登录凭据。
@main
struct ShareExtensionSmoke {
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() {
            throw NSError(domain: "分享扩展行为验证", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: message])
        }
    }

    static func main() throws {
        let links: [(String, String, Int, Int?)] = [
            ("https://linux.do/t/12345", "linux.do", 12345, nil),
            ("帖子标题\nhttps://linux.do/t/中文标题/12345/6?u=reader", "linux.do", 12345, 6),
            ("https://idcflare.com/t/topic/987/1", "idcflare.com", 987, 1),
        ]
        for (text, host, id, floor) in links {
            let parsed = try SharedTopicLink.parse(text)
            try require(parsed.host == host && parsed.topicID == id && parsed.postNumber == floor,
                        "帖子站点、ID 或楼层解析错误")
        }
        let rejected = [
            "https://linux.do.evil.example/t/12345", "https://sub.linux.do/t/12345",
            "https://linux.do@evil.example/t/12345", "https://user@linux.do/t/12345",
            "https://linux.do:8443/t/12345", "http://linux.do/t/12345",
            "https://linux.do/t/0", "https://linux.do/t/12345/0",
            "https://linux.do/t/12345/1/extra", "https://linux.do/t/%2F/12345",
            "https://linux.do/t/12345 https://idcflare.com/t/987",
        ]
        for text in rejected {
            do {
                _ = try SharedTopicLink.parse(text)
            } catch { continue }
            throw NSError(domain: "分享扩展行为验证", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "错误接受非预期输入：\(text)"])
        }
        print("通过：两站链接、中文标题、楼层，以及假域名/多链接/异常路径拒绝边界")

        let link = try SharedTopicLink.parse("https://linux.do/t/12345")
        let post = SharedPost(id: 123, postNumber: 1, username: "user<unsafe>", cooked: """
        <p>正文<strong>强调</strong>与图片</p>
        <img src="/uploads/default/original/example.png" onerror="alert(1)">
        <a href="/t/456">站内链接</a>
        <a href="jav&#x61;script:alert(1)" onclick="alert(1)">危险链接</a>
        <script>alert('secret')</script><iframe src="https://evil.example"></iframe>
        """)
        let topic = SharedTopic(id: 12345, title: "标题<script>不会执行</script>", slug: "topic",
                                posts: [post], postIDs: [123], url: link.url)
        let client = ForumShareClient(link: link)
        let html = client.html(topic: topic, posts: [post])
        try require(html.contains("<strong>强调</strong>") && html.contains("正文"), "导出丢失正文结构")
        try require(html.contains("src=\"https://linux.do/uploads/default/original/example.png\""), "相对图片未转绝对地址")
        try require(html.contains("href=\"https://linux.do/t/456\""), "相对链接未转绝对地址")
        try require(html.contains("user&lt;unsafe&gt;") && html.contains("标题&lt;script&gt;"), "标题或作者可注入标签")
        try require(!html.contains("<script") && !html.contains("<iframe")
                    && !html.contains("onerror=") && !html.contains("onclick=")
                    && !html.contains("javascript:"), "导出包含可执行正文")
        let imageHTML = client.html(topic: topic, posts: [post], imageScheme: "fluxdo-share-image")
        try require(imageHTML.contains("src=\"fluxdo-share-image://linux.do/uploads/default/original/example.png\""),
                    "图片预览未走认证隔离的图片加载通道")
        print("通过：正文与相对资源保留、脚本/事件/危险链接隔离，以及图片代理地址")
    }
}
