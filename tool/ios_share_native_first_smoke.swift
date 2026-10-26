import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// 离线执行生产客户端，验证原生接口优先和网页回退顺序。
@main
@MainActor
struct ShareNativeFirstSmoke {
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() {
            throw NSError(domain: "接口优先回归", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
        }
    }

    static func response(_ url: URL, _ data: Data, status: Int = 200,
                         headers: [String: String] = ["Content-Type": "application/json"]) -> (Data, HTTPURLResponse) {
        (data, HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!)
    }

    static func main() async throws {
        let post: [String: Any] = ["id": 123, "topic_id": 12345, "post_number": 1,
                                   "username": "reader", "cooked": "<p>接口正文</p>", "raw": "接口原文"]
        let payload = try JSONSerialization.data(withJSONObject: [
            "id": 12345, "title": "接口优先", "post_stream": ["stream": [123], "posts": [post]],
        ])
        let raw = try JSONSerialization.data(withJSONObject: post)
        for host in ["linux.do", "idcflare.com"] {
            let link = try SharedTopicLink.parse("https://\(host)/t/12345")
            var events: [String] = []
            var cookie = "_t=first"
            let client = ForumShareClient(link: link, nativeLoader: { request in
                try require(request.url?.host == host, "原生请求跨站")
                try require(request.value(forHTTPHeaderField: "Cookie") == cookie, "未使用当前扩展会话")
                try require(request.value(forHTTPHeaderField: "User-Agent") == "配对 UA", "Cookie 与 UA 未配对")
                try require(request.value(forHTTPHeaderField: "X-Requested-With") == "XMLHttpRequest", "丢失主应用 XHR 语义")
                try require(request.value(forHTTPHeaderField: "Accept") == "application/json, text/javascript, */*; q=0.01", "JSON 请求头与主应用不一致")
                events.append("native:\(request.url!.path)")
                let data = request.url!.path.hasPrefix("/posts/") ? raw : payload
                return response(request.url!, data, headers: ["Content-Type": "application/json", "Set-Cookie": "_t=renewed; Path=/; Secure"])
            }, sessionProvider: { url in
                try require(url.host == host, "会话读取跨站")
                return ShareSession(cookieHeader: cookie, userAgent: "配对 UA")
            }, responseHandler: { http in
                if http.value(forHTTPHeaderField: "Set-Cookie") != nil { cookie = "_t=renewed" }
            }, fallbackLoader: { url in
                events.append("browser")
                return response(url, payload)
            })
            let topic = try await client.loadTopic()
            let text = try await client.markdown(topic: topic, posts: topic.posts)
            try require(topic.title == "接口优先" && text.contains("接口原文"), "原生接口未完成帖子与原文读取")
            try require(events == ["native:/t/12345.json", "native:/posts/123.json"] && !client.usesBrowser,
                        "原生成功仍调用了网页回退")
            try require(cookie == "_t=renewed", "未回传服务端会话轮换")
        }
        let link = try SharedTopicLink.parse("https://linux.do/t/12345")
        let failures: [(Int, String, [String: String])] = [
            (403, "<html>challenge</html>", ["cf-mitigated": "challenge"]),
            (401, "{}", [:]), (403, "{}", [:]), (503, "{}", [:]),
            (200, "损坏 JSON", [:]), (200, "{}", [:]),
        ]
        for (status, body, headers) in failures {
            var events: [String] = []
            let client = ForumShareClient(link: link, nativeLoader: { request in
                events.append("native")
                return response(request.url!, Data(body.utf8), status: status, headers: headers)
            }, fallbackLoader: { url in
                events.append("browser:\(url.path)")
                return response(url, url.path.hasPrefix("/posts/") ? raw : payload)
            }, fallbackImageLoader: { url in
                events.append("image")
                return response(url, Data([1, 2, 3]), headers: ["Content-Type": "image/png"])
            })
            let topic = try await client.loadTopic()
            _ = try await client.markdown(topic: topic, posts: topic.posts)
            _ = try await client.image(URL(string: "https://linux.do/avatar.png")!)
            try require(events == ["native", "browser:/t/12345.json", "browser:/posts/123.json", "image"],
                        "接口失败后未一次切换并复用网页通道")
            try require(client.usesBrowser && client.nativeFailure != nil && client.lastHTTPStatus == 200,
                        "回退诊断缺失")
        }
        for error: Error in [CancellationError(), URLError(.cancelled), ForumShareError.rateLimited,
                             ForumShareError.unavailable, ForumShareError.unsafeRedirect, ForumShareError.invalidLink] {
            var fallbackCount = 0
            let client = ForumShareClient(link: link, nativeLoader: { _ in throw error }, fallbackLoader: { url in
                fallbackCount += 1
                return response(url, payload)
            })
            var failed = false
            do { _ = try await client.loadTopic() } catch { failed = true }
            try require(failed, "取消或确定性失败被吞并")
            try require(fallbackCount == 0 && !client.usesBrowser, "取消、限流、失效链接或安全错误触发网页回退")
        }
        var attempts = 0
        var verified = false
        let broken = ForumShareClient(link: link, nativeLoader: { _ in throw URLError(.timedOut) }, fallbackLoader: { url in
            attempts += 1
            if !verified { throw ForumShareError.cloudflare }
            return response(url, payload)
        })
        do { _ = try await broken.loadTopic(); try require(false, "网页失败被吞并") }
        catch ForumShareError.cloudflare {}
        try require(attempts == 1, "网页失败形成循环重试")
        verified = true
        _ = try await broken.loadTopic()
        try require(attempts == 2, "验证后继续未复用网页通道")

        var nativeCalls = 0
        let resumed = ForumShareClient(link: link, nativeLoader: { request in
            nativeCalls += 1
            return response(request.url!, payload)
        }, fallbackLoader: { url in response(url, payload) }, startsInBrowser: true)
        _ = try await resumed.loadTopic()
        try require(nativeCalls == 0, "已完成网页验证后的重试再次尝试原生通道")

        var imageEvents: [String] = []
        let imageClient = ForumShareClient(link: link, nativeLoader: { request in
            imageEvents.append("native")
            return response(request.url!, Data(), status: 403, headers: ["cf-mitigated": "challenge"])
        }, fallbackImageLoader: { url in
            imageEvents.append("browser")
            return response(url, Data([1, 2, 3]), headers: ["Content-Type": "image/png"])
        })
        _ = try await imageClient.image(URL(string: "https://linux.do/photo.png")!)
        try require(imageEvents == ["native", "browser"], "图片请求未回退网页通道")
        do {
            _ = try await imageClient.image(URL(string: "https://evil.example/photo.png")!)
            try require(false, "同站图片通道接受了跨站图片")
        } catch ForumShareError.invalidLink {}

        let floorLink = try SharedTopicLink.parse("https://linux.do/t/12345/2")
        let allPosts: [[String: Any]] = (1...25).map { number in
            ["id": 100 + number, "topic_id": 12345, "post_number": number,
             "username": "reader", "cooked": "<p>第 \(number) 楼</p>", "raw": "第 \(number) 楼原文"]
        }
        let floorPayload = try JSONSerialization.data(withJSONObject: [
            "id": 12345, "title": "楼层链接", "post_stream": ["stream": Array(101...125), "posts": [allPosts[1]]],
        ])
        var batches: [Int] = []
        let exportClient = ForumShareClient(link: floorLink, nativeLoader: { request in
            let url = request.url!
            if url.path == "/t/12345/2.json" { return response(url, floorPayload) }
            if url.path == "/posts/by_number/12345/1" {
                return response(url, try JSONSerialization.data(withJSONObject: allPosts[0]))
            }
            return response(url, Data(), status: 403, headers: ["cf-mitigated": "challenge"])
        }, fallbackLoader: { url in
            if url.path == "/t/12345/posts.json" {
                let ids = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.map { Int($0.value!)! }
                batches.append(ids.count)
                let posts = allPosts.filter { ids.contains($0["id"] as! Int) }
                return response(url, try JSONSerialization.data(withJSONObject: ["post_stream": ["posts": posts]]))
            }
            let id = Int(url.deletingPathExtension().lastPathComponent)!
            return response(url, try JSONSerialization.data(withJSONObject: allPosts[id - 101]))
        })
        let floorTopic = try await exportClient.loadTopic()
        try require(floorTopic.posts.first?.postNumber == 1, "楼层链接没有补取主帖")
        let complete = try await exportClient.posts(topic: floorTopic, all: true, markdown: false)
        let markdown = try await exportClient.markdown(topic: floorTopic, posts: Array(complete.prefix(10)))
        try require(complete.count == 25 && batches == [20, 3] && markdown.contains("第 10 楼原文"),
                    "补帖中途回退未完成全量导出或 Markdown 原文")

        var activeImages = 0
        var peakImages = 0
        let serialImages = ForumShareClient(link: link, nativeLoader: { request in
            activeImages += 1
            peakImages = max(peakImages, activeImages)
            defer { activeImages -= 1 }
            try await Task.sleep(nanoseconds: 1_000_000)
            return response(request.url!, Data([1, 2, 3]), headers: ["Content-Type": "image/png"])
        })
        async let firstImage = serialImages.image(URL(string: "https://linux.do/1.png")!)
        async let secondImage = serialImages.image(URL(string: "https://linux.do/2.png")!)
        _ = try await (firstImage, secondImage)
        try require(peakImages == 1 && !serialImages.usesBrowser, "原生图片未串行读取或成功后触发网页")
        for destination in ["https://linux.do/posts/123.json", "https://linux.do/other/path", "https://evil.example/steal"] {
            var current = "_t=old"
            var paths: [String] = []
            let policy = ShareRedirectPolicy(host: "linux.do", sessionProvider: { url in
                paths.append(url.path)
                return ShareSession(cookieHeader: url.path.hasPrefix("/posts/") ? current : "", userAgent: "配对 UA")
            }, responseHandler: { http in
                if http.value(forHTTPHeaderField: "Set-Cookie") != nil { current = "_t=new" }
            })
            let redirect = response(link.url, Data(), status: 302, headers: ["Set-Cookie": "_t=new; Path=/; Secure"]).1
            let task = URLSession.shared.dataTask(with: link.url)
            let next: URLRequest? = await withCheckedContinuation { continuation in
                policy.urlSession(URLSession.shared, task: task, willPerformHTTPRedirection: redirect,
                                  newRequest: URLRequest(url: URL(string: destination)!)) { request in
                    continuation.resume(returning: request)
                }
            }
            task.cancel()
            try require(current == "_t=new", "同源跳转响应的 Cookie 轮换丢失")
            if destination.contains("evil.example") {
                try require(next == nil && paths.isEmpty, "跨站跳转读取或转发凭据")
            } else {
                let expected = destination.contains("/posts/") ? "_t=new" : ""
                try require(next?.value(forHTTPHeaderField: "Cookie") == expected && paths.count == 1,
                            "跳转未按目标路径选择更新后的 Cookie")
            }
        }
        print("通过：两站接口优先、Cookie/UA 配对和轮换、单次回退、楼层链接与全量导出、图片串行、同源跳转及取消边界")
    }
}
