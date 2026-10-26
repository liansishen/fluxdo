import Foundation

/// 在 macOS CI 直接运行生产解析器、共享会话与 HTML 导出器，不依赖主应用或登录凭据。
@main
struct ShareExtensionSmoke {
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() {
            throw NSError(domain: "分享扩展行为验证", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: message])
        }
    }

    /// 构造包含 XML 内容的 CMS SignedData，避免把源码文本当作行为验证。
    static func cmsProfile(_ plist: [String: Any]) throws -> Data {
        func der(_ tag: UInt8, _ body: Data) -> Data {
            var result = Data([tag])
            if body.count < 128 {
                result.append(UInt8(body.count))
            } else {
                var count = body.count
                var length: [UInt8] = []
                while count > 0 {
                    length.append(UInt8(count & 0xff))
                    count >>= 8
                }
                result.append(0x80 | UInt8(length.count))
                result.append(contentsOf: length.reversed())
            }
            result.append(body)
            return result
        }
        let xml = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        let signedDataOID = der(0x06, Data([0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x07, 0x02]))
        let dataOID = der(0x06, Data([0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x07, 0x01]))
        let content = der(0x30, dataOID + der(0xa0, der(0x04, xml)))
        let signedData = der(0x30, Data([0x02, 0x01, 0x01, 0x31, 0x00]) + content + Data([0x31, 0x00]))
        return der(0x30, signedDataOID + der(0xa0, signedData))
    }

    static func checkSharedGroups() throws {
        let original = ShareAppGroupResolver.originalGroup
        let teamGroup = original + ".ABCDE12345"
        let otherTeamGroup = original + ".ZYXWV98765"
        let groupsKey = "com.apple.security.application-groups"
        func profile(_ groups: [String]) throws -> Data {
            try cmsProfile(["Entitlements": [groupsKey: groups]])
        }
        let wrapped = try profile(["group.unrelated.example", teamGroup])
        try require(ShareAppGroupResolver.profileGroups(from: wrapped) == ["group.unrelated.example", teamGroup],
                    "未从 CMS 包裹的 XML 描述文件读取授权组")
        try require(ShareAppGroupResolver.resolve(profileData: wrapped, altAppGroups: nil) == teamGroup,
                    "缺少 ALTAppGroups 时未读取描述文件中的侧载组")
        try require(ShareAppGroupResolver.resolve(profileData: wrapped, altAppGroups: [original, otherTeamGroup]) == teamGroup,
                    "描述文件没有独占优先于旧版侧载元数据")
        let originalProfile = try profile([original])
        try require(ShareAppGroupResolver.resolve(profileData: originalProfile, altAppGroups: [teamGroup]) == original,
                    "原始授权组解析失败")
        try require(ShareAppGroupResolver.resolve(profileData: nil, altAppGroups: [teamGroup]) == teamGroup,
                    "旧版 ALTAppGroups 回退解析失败")
        try require(ShareAppGroupResolver.resolve(profileData: nil, altAppGroups: [original]) == original,
                    "ALTAppGroups 中的原始组解析失败")
        try require(ShareAppGroupResolver.resolve(profileData: nil, altAppGroups: nil) == original,
                    "无侧载资料时未保留原组系统校验路径")

        let malicious = [
            "evil." + original, original + "evil", original + ".abcde12345",
            original + ".ABCDE1234", original + ".ABCDE123456", original + ".ABCDE12345.extra",
            original + ".ABCDE12345.ZYXWV98765", original + ".ＡBCDE12345",
            "group.unrelated.example",
        ]
        for group in malicious {
            try require(!ShareAppGroupResolver.isAllowed(group), "错误接受相似前缀、非法团队标识或额外后缀")
            let invalidProfile = try profile([group])
            try require(ShareAppGroupResolver.resolve(profileData: invalidProfile, altAppGroups: [teamGroup]) == nil,
                        "描述文件中的非法组回退越过了授权来源")
            try require(ShareAppGroupResolver.resolve(profileData: nil, altAppGroups: [group]) == nil,
                        "侧载元数据中的非法组回退到了原组")
        }
        for groups in [[original, teamGroup], [teamGroup, otherTeamGroup], [otherTeamGroup, teamGroup]] {
            let ambiguous = try profile(groups)
            try require(ShareAppGroupResolver.resolve(profileData: ambiguous, altAppGroups: [original]) == nil,
                        "描述文件多个匹配组被静默选择")
            try require(ShareAppGroupResolver.resolve(profileData: nil, altAppGroups: groups) == nil,
                        "侧载元数据多个匹配组被静默选择")
        }
        let duplicated = try profile([teamGroup, teamGroup])
        try require(ShareAppGroupResolver.resolve(profileData: duplicated, altAppGroups: nil) == teamGroup,
                    "同一授权组重复出现被误判为多个容器")
        let missingGroups = try cmsProfile(["Entitlements": [String: Any]()])
        let missingEntitlements = try cmsProfile(["Name": "无授权资料"])
        let malformedGroups = try cmsProfile(["Entitlements": [groupsKey: teamGroup]])
        let emptyGroups = try profile([])
        for data in [Data(), Data([0x30, 0x82, 0xff]), Data("<?xml version=\"1.0\"?><plist>损坏".utf8),
                     missingGroups, missingEntitlements, malformedGroups, emptyGroups] {
            try require(ShareAppGroupResolver.resolve(profileData: data, altAppGroups: [teamGroup]) == nil,
                        "损坏或缺组描述文件错误回退到 ALTAppGroups")
            try require(ShareAppGroupResolver.resolve(profileData: data, altAppGroups: nil) == nil,
                        "损坏或缺组描述文件错误回退到原组")
        }
        try require(ShareAppGroupResolver.resolve(profileData: nil, altAppGroups: []) == nil,
                    "空侧载授权组错误回退到原组")
        print("通过：CMS 描述文件、ALTAppGroups、严格团队后缀、授权来源优先级与歧义拒绝")
    }

    static func checkStoredSessions() throws {
        func session(_ header: String, expirations: [String: Double] = [:]) throws -> Data {
            try JSONSerialization.data(withJSONObject: [
                "cookieHeader": header, "userAgent": "原生回归客户端", "cookieExpirations": expirations,
            ])
        }
        let now = 10_000.0
        let mixed = try session("_t=token; _forum_session=session; cf_clearance=clearance",
                                expirations: ["_t": now - 1, "_forum_session": now + 1])
        let decoded = try ShareSessionStore.decodeSession(mixed, now: now)
        try require(decoded.cookieHeader == "_forum_session=session; cf_clearance=clearance",
                    "未逐个移除过期 Cookie 或错误移除了会话 Cookie")
        let expired = try session("_t=token", expirations: ["_t": now])
        do {
            _ = try ShareSessionStore.decodeSession(expired, now: now)
            try require(false, "全部 Cookie 过期未报告 expiredSession")
        } catch ShareSessionStore.StoreError.expiredSession {}
        let invalid = try [
            session("unexpected=secret"), session("_t=first; _t=second"), session("_t=bad\r\nvalue"),
            session(""), session("_t=token", expirations: ["unexpected": now + 1]),
        ]
        for data in invalid + [Data("损坏 JSON".utf8)] {
            do {
                _ = try ShareSessionStore.decodeSession(data, now: now)
                try require(false, "损坏或越界 Cookie 会话未报告 invalidSession")
            } catch ShareSessionStore.StoreError.invalidSession {}
        }
        do {
            _ = try ShareSessionStore.readSession(host: "evil.example")
            try require(false, "不支持的论坛域名未被拒绝")
        } catch ShareSessionStore.StoreError.unsupportedHost {}
        try require(ShareSessionStore.read(host: "evil.example") == nil, "匿名读取包装未吞并会话错误")
        print("通过：会话有效期、Cookie 名称与内容隔离，以及匿名读取包装")
    }

    static func checkRequestRecovery() async throws {
        let link = try SharedTopicLink.parse("https://linux.do/t/12345")
        let post: [String: Any] = ["id": 123, "topic_id": 12345, "post_number": 1,
                                   "username": "reader", "cooked": "<p>完整正文</p>"]
        let topic: [String: Any] = ["id": 12345, "title": "测试主题",
                                    "post_stream": ["stream": [123], "posts": [post]]]
        let payload = try JSONSerialization.data(withJSONObject: topic)
        actor Responses {
            var count = 0
            func next(_ url: URL, payload: Data) -> (Data, HTTPURLResponse) {
                count += 1
                if count == 1 {
                    return (Data("<html>challenge</html>".utf8), HTTPURLResponse(url: url, statusCode: 403,
                            httpVersion: "HTTP/1.1", headerFields: ["cf-mitigated": "challenge"])!)
                }
                return (payload, HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                                headerFields: ["Content-Type": "application/json"])!)
            }
        }
        let responses = Responses()
        let client = ForumShareClient(link: link, loader: { url in
            try require(url.host == "linux.do" && url.path == "/t/12345.json", "请求离开原始主题接口")
            return await responses.next(url, payload: payload)
        })
        do {
            _ = try await client.loadTopic()
            try require(false, "Cloudflare 挑战被误判为成功")
        } catch ForumShareError.cloudflare {}
        try require(client.lastHTTPStatus == 403, "诊断未记录挑战状态码")
        let loaded = try await client.loadTopic()
        try require(loaded.id == 12345 && loaded.posts.first?.cooked == "<p>完整正文</p>",
                    "验证后继续未读取完整主帖")
        try require(client.lastHTTPStatus == 200, "恢复后未更新 HTTP 诊断")
        let cases: [(Int, String, ForumShareError)] = [
            (401, "{}", .loginRequired), (403, "{}", .accessDenied),
            (429, "{}", .rateLimited), (404, "{}", .unavailable), (200, "not json", .invalidResponse),
        ]
        for (status, body, expected) in cases {
            let client = ForumShareClient(link: link, loader: { url in
                (Data(body.utf8), HTTPURLResponse(url: url, statusCode: status,
                                                httpVersion: "HTTP/1.1", headerFields: nil)!)
            })
            do {
                _ = try await client.loadTopic()
                try require(false, "失败响应被误判为主题")
            } catch let error as ForumShareError {
                try require(String(describing: error) == String(describing: expected), "恢复错误分类发生回归")
            }
        }
        let unsafe = ForumShareClient(link: link, loader: { _ in
            (payload, HTTPURLResponse(url: URL(string: "https://evil.example/t/12345")!, statusCode: 200,
                                      httpVersion: "HTTP/1.1", headerFields: nil)!)
        })
        do {
            _ = try await unsafe.loadTopic()
            try require(false, "接受了跨站响应")
        } catch ForumShareError.unsafeRedirect {}
        let cancelled = ForumShareClient(link: link, loader: { _ in throw CancellationError() })
        do {
            _ = try await cancelled.loadTopic()
            try require(false, "取消请求被当作成功")
        } catch is CancellationError {}
        let authentication = ForumShareClient(link: link, loader: { _ in throw ForumShareError.loginRequired })
        do {
            _ = try await authentication.loadTopic()
            try require(false, "WebKit 登录错误丢失")
        } catch ForumShareError.loginRequired {}
        print("通过：挑战后继续、登录与权限错误、HTTP 诊断、跨站响应拒绝和取消")
    }

    static func main() async throws {
        try await checkRequestRecovery()
        try checkSharedGroups()
        try checkStoredSessions()
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
