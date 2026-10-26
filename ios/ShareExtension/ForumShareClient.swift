import Foundation

struct SharedTopicLink {
    let url: URL
    let host: String
    let topicID: Int
    let postNumber: Int?

    static let supportedHosts: Set<String> = ["linux.do", "idcflare.com"]

    static func parse(_ text: String) throws -> SharedTopicLink {
        let expression = try NSRegularExpression(pattern: #"(?i)[a-z][a-z0-9+.-]*://[^\s<>\"“”]+"#)
        let matches = expression.matches(in: text, range: NSRange(text.startIndex..., in: text))
        guard matches.count == 1, let range = Range(matches[0].range, in: text) else {
            throw ForumShareError.invalidLink
        }
        var candidate = String(text[range])
        // 分享标题常以中文标点或括号收尾；路径自身仍必须完整匹配话题格式。
        while let last = candidate.last, "，。；、！？”’）)]}".contains(last) {
            candidate.removeLast()
        }
        guard let components = URLComponents(string: candidate),
              components.scheme?.lowercased() == "https",
              let host = components.host?.lowercased(), supportedHosts.contains(host),
              components.user == nil, components.password == nil,
              components.port == nil || components.port == 443,
              let authorityStart = candidate.range(of: "://")?.upperBound else {
            throw ForumShareError.invalidLink
        }
        let authority = candidate[authorityStart...].prefix { $0 != "/" && $0 != "?" && $0 != "#" }.lowercased()
        guard authority == host || authority == "\(host):443" else {
            throw ForumShareError.invalidLink
        }
        var path = components.percentEncodedPath
        if path.hasSuffix("/") { path.removeLast() }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard (3...5).contains(parts.count), parts[0].isEmpty, parts[1] == "t" else {
            throw ForumShareError.invalidLink
        }
        func positiveInteger(_ value: Substring) -> Int? {
            guard !value.isEmpty, value.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
                  let number = Int(value), number > 0 else { return nil }
            return number
        }
        let id: Int
        let floor: Int?
        if let number = positiveInteger(parts[2]), parts.count <= 4 {
            id = number
            floor = parts.count == 4 ? positiveInteger(parts[3]) : nil
            if parts.count == 4 && floor == nil { throw ForumShareError.invalidLink }
        } else {
            guard parts.count >= 4, let slug = String(parts[2]).removingPercentEncoding,
                  !slug.isEmpty, slug != ".", slug != "..",
                  !slug.contains(where: { $0 == "/" || $0 == "\\" || $0.isWhitespace || $0.isNewline }),
                  !slug.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
                  let number = positiveInteger(parts[3]) else { throw ForumShareError.invalidLink }
            id = number
            floor = parts.count == 5 ? positiveInteger(parts[4]) : nil
            if parts.count == 5 && floor == nil { throw ForumShareError.invalidLink }
        }
        guard let url = URL(string: "https://\(host)/t/\(id)" + (floor.map { "/\($0)" } ?? "")) else {
            throw ForumShareError.invalidLink
        }
        return SharedTopicLink(url: url, host: host, topicID: id, postNumber: floor)
    }
}

struct SharedTopic {
    let id: Int
    let title: String
    let slug: String
    let posts: [SharedPost]
    let postIDs: [Int]
    let url: URL
}

struct SharedPost {
    let id: Int
    let postNumber: Int
    let username: String
    let cooked: String
}

enum ForumShareError: LocalizedError {
    case invalidLink, invalidResponse, network, loginRequired, accessDenied
    case cloudflare, rateLimited, unavailable, unsafeRedirect, incompletePosts, missingRaw

    var errorDescription: String? {
        switch self {
        case .invalidLink: return "请分享 linux.do 或 idcflare.com 的 HTTPS 话题链接。暂不支持其他站点或链接格式。"
        case .invalidResponse: return "论坛返回的数据不完整或格式异常，请稍后重试。"
        case .network: return "无法连接论坛，请检查网络后重试。"
        case .loginRequired: return "此内容需要登录。请在下方网页登录对应站点，再点击“验证完成，继续保存”。"
        case .accessDenied: return "当前会话无权访问此内容，可在下方网页确认登录账号和帖子权限。"
        case .cloudflare: return "请在下方网页完成 Cloudflare 验证，再点击“验证完成，继续保存”。"
        case .rateLimited: return "论坛请求过于频繁，请稍后再试。"
        case .unavailable: return "话题或帖子不存在、已删除，或当前账号无法访问。"
        case .unsafeRedirect: return "论坛返回了不安全或不支持的跳转，已停止请求以保护登录信息。"
        case .incompletePosts: return "未能取得全部所选帖子，已停止导出，避免把不完整内容标记为全部。"
        case .missingRaw: return "无法取得帖子的 Markdown 原文，已停止导出；不会使用网页内容代替原文。"
        }
    }
}

private final class ShareRedirectPolicy: NSObject, URLSessionTaskDelegate {
    let host: String

    init(host: String) { self.host = host }

    static func isAllowed(_ url: URL, host: String) -> Bool {
        guard SharedTopicLink.supportedHosts.contains(host),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        return components.scheme?.lowercased() == "https" && components.host?.lowercased() == host
            && components.user == nil && components.password == nil
            && (components.port == nil || components.port == 443)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url, Self.isAllowed(url, host: host) else {
            completionHandler(nil)
            return
        }
        var next = request
        // 系统 Cookie 存储完全关闭，只向原始、精确匹配的站点显式附加共享会话。
        next.setValue(nil, forHTTPHeaderField: "Cookie")
        if let saved = ShareSessionStore.read(host: host) {
            next.setValue(saved.cookieHeader, forHTTPHeaderField: "Cookie")
            next.setValue(saved.userAgent, forHTTPHeaderField: "User-Agent")
        }
        completionHandler(next)
    }
}

final class ForumShareClient {
    private let link: SharedTopicLink
    private let session: URLSession
    typealias Loader = (URL) async throws -> (Data, HTTPURLResponse)
    private let loader: Loader?
    private(set) var lastHTTPStatus: Int?

    init(link: SharedTopicLink, loader: Loader? = nil) {
        self.link = link
        self.loader = loader
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 90
        session = URLSession(configuration: configuration, delegate: ShareRedirectPolicy(host: link.host), delegateQueue: nil)
    }

    deinit { session.invalidateAndCancel() }

    func loadTopic() async throws -> SharedTopic {
        let suffix = link.postNumber.map { "/\($0)" } ?? ""
        let json = try await request(path: "/t/\(link.topicID)\(suffix).json")
        guard let id = json["id"] as? Int, id == link.topicID,
              let title = json["title"] as? String, !title.isEmpty,
              let stream = json["post_stream"] as? [String: Any],
              let ids = stream["stream"] as? [Int], !ids.isEmpty,
              ids.allSatisfy({ $0 > 0 }), Set(ids).count == ids.count,
              let values = stream["posts"] as? [[String: Any]],
              let url = URL(string: "https://\(link.host)/t/\(id)") else { throw ForumShareError.invalidResponse }
        var posts = try values.map { try parsePost($0, topicID: id) }
        if !posts.contains(where: { $0.postNumber == 1 }) {
            // 分享楼层链接时首屏可能不含主帖，必须单独取真正的第 1 楼。
            let first = try await request(path: "/posts/by_number/\(id)/1")
            let post = try parsePost(first, topicID: id)
            guard post.postNumber == 1 else { throw ForumShareError.incompletePosts }
            posts.append(post)
        }
        guard let first = posts.first(where: { $0.postNumber == 1 }), ids.contains(first.id),
              posts.allSatisfy({ ids.contains($0.id) }),
              Set(posts.map(\.id)).count == posts.count,
              Set(posts.map(\.postNumber)).count == posts.count else { throw ForumShareError.incompletePosts }
        return SharedTopic(id: id, title: title, slug: json["slug"] as? String ?? "",
                           posts: posts.sorted { $0.postNumber < $1.postNumber }, postIDs: ids, url: url)
    }

    func posts(topic: SharedTopic, all: Bool, markdown: Bool) async throws -> [SharedPost] {
        try validate(topic)
        guard let first = topic.posts.first(where: { $0.postNumber == 1 }) else { throw ForumShareError.incompletePosts }
        if !all { return [first] }
        let wanted = markdown ? Array(topic.postIDs.prefix(10)) : topic.postIDs
        guard wanted.contains(first.id) else { throw ForumShareError.incompletePosts }
        var available = Dictionary(topic.posts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let missing = wanted.filter { available[$0] == nil }
        // 与 Dart getPosts 一致，按 stream 的帖子 ID 分批请求，不以首屏冒充全量。
        for start in stride(from: 0, to: missing.count, by: 20) {
            try Task.checkCancellation()
            let batch = Array(missing[start..<min(start + 20, missing.count)])
            let json = try await request(path: "/t/\(topic.id)/posts.json",
                                         query: batch.map { URLQueryItem(name: "post_ids[]", value: String($0)) })
            guard let stream = json["post_stream"] as? [String: Any],
                  let values = stream["posts"] as? [[String: Any]] else { throw ForumShareError.incompletePosts }
            var received = Set<Int>()
            for value in values {
                let post = try parsePost(value, topicID: topic.id)
                guard batch.contains(post.id), received.insert(post.id).inserted else { throw ForumShareError.incompletePosts }
                available[post.id] = post
            }
            guard received == Set(batch) else { throw ForumShareError.incompletePosts }
        }
        let result = try wanted.map { id -> SharedPost in
            guard let post = available[id] else { throw ForumShareError.incompletePosts }
            return post
        }
        guard Set(result.map(\.postNumber)).count == result.count else { throw ForumShareError.incompletePosts }
        return result.sorted { $0.postNumber < $1.postNumber }
    }

    func markdown(topic: SharedTopic, posts: [SharedPost]) async throws -> String {
        try validate(topic)
        guard !posts.isEmpty else { throw ForumShareError.incompletePosts }
        var sections = ["# \(markdownText(topic.title))", "来源：\(topic.url.absoluteString)",
                        "> Markdown 导出最多包含所选范围的前 10 条帖子；需要全部回复请使用 HTML 导出。"]
        for post in posts.prefix(10) {
            try Task.checkCancellation()
            guard topic.postIDs.contains(post.id) else { throw ForumShareError.incompletePosts }
            // 与 Dart getPostRaw 一致，读取 /posts/{id}.json 的 raw，绝不把 cooked 当原文。
            let json = try await request(path: "/posts/\(post.id).json")
            guard json["id"] as? Int == post.id,
                  json["topic_id"] as? Int == topic.id,
                  json["post_number"] as? Int == post.postNumber,
                  let raw = json["raw"] as? String else { throw ForumShareError.missingRaw }
            sections.append("## \(markdownText(post.username)) · 第 \(post.postNumber) 楼\n\n\(raw)")
        }
        return sections.joined(separator: "\n\n") + "\n"
    }

    func html(topic: SharedTopic, posts: [SharedPost], imageScheme: String? = nil) -> String {
        let imageSource = imageScheme == "fluxdo-share-image" ? "fluxdo-share-image" : "https"
        let title = SafeShareHTML.escape(topic.title)
        let source = SafeShareHTML.escape(topic.url.absoluteString)
        let body = posts.map { post in
            "<article><h2>\(SafeShareHTML.escape(post.username)) · 第 \(post.postNumber) 楼</h2>"
                + SafeShareHTML.clean(post.cooked, baseURL: topic.url, imageScheme: imageSource) + "</article>"
        }.joined(separator: "\n")
        let screenshotStyle = imageSource == "fluxdo-share-image"
            ? "<style>pre{white-space:pre-wrap;overflow-wrap:anywhere;word-break:break-word;overflow:visible}table{display:table;width:100%;table-layout:fixed}td,th{overflow-wrap:anywhere;word-break:break-word}</style>"
            : ""
        return """
        <!doctype html><html lang="zh-CN"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'none'; style-src 'unsafe-inline'; img-src \(imageSource):; frame-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'; connect-src 'none'; media-src 'none'">
        <meta name="referrer" content="no-referrer"><title>\(title)</title>
        <style>body{font:17px/1.7 -apple-system,BlinkMacSystemFont,sans-serif;max-width:860px;margin:auto;padding:24px;overflow-wrap:anywhere;color:#202124;background:white}h1{font-size:28px;line-height:1.4}h2{font-size:17px;color:#60656d}article{border-top:1px solid #ddd;margin-top:24px;padding-top:16px}img{max-width:100%;height:auto}pre{overflow:auto;background:#f4f4f4;padding:12px}blockquote{border-left:3px solid #aaa;margin-left:0;padding-left:16px}table{border-collapse:collapse;display:block;overflow:auto}td,th{border:1px solid #ddd;padding:6px}a{color:#1769aa}</style>
        \(screenshotStyle)
        </head><body><header><h1>\(title)</h1><p>来源：<a href="\(source)" rel="noreferrer noopener">\(source)</a></p></header>
        \(body)
        </body></html>
        """
    }

    private func validate(_ topic: SharedTopic) throws {
        guard topic.id == link.topicID, ShareRedirectPolicy.isAllowed(topic.url, host: link.host) else {
            throw ForumShareError.invalidLink
        }
    }

    private func parsePost(_ json: [String: Any], topicID: Int) throws -> SharedPost {
        guard let id = json["id"] as? Int, id > 0,
              let number = json["post_number"] as? Int, number > 0,
              let username = json["username"] as? String,
              let cooked = json["cooked"] as? String,
              json["topic_id"] == nil || json["topic_id"] as? Int == topicID else { throw ForumShareError.invalidResponse }
        return SharedPost(id: id, postNumber: number, username: username, cooked: cooked)
    }

    private func request(path: String, query: [URLQueryItem] = []) async throws -> [String: Any] {
        guard var components = URLComponents(string: "https://\(link.host)"),
              SharedTopicLink.supportedHosts.contains(link.host) else { throw ForumShareError.invalidLink }
        components.path = path
        components.queryItems = query.isEmpty ? nil : query
        guard let url = components.url, ShareRedirectPolicy.isAllowed(url, host: link.host) else { throw ForumShareError.invalidLink }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        if let saved = ShareSessionStore.read(host: link.host) {
            request.setValue(saved.cookieHeader, forHTTPHeaderField: "Cookie")
            request.setValue(saved.userAgent, forHTTPHeaderField: "User-Agent")
        }
        let data: Data
        let response: URLResponse
        do {
            try Task.checkCancellation()
            if let loader = loader {
                (data, response) = try await loader(url)
            } else {
                (data, response) = try await session.data(for: request)
            }
            try Task.checkCancellation()
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch let error as ForumShareError {
            throw error
        } catch {
            // 不向 UI 传递含 URL、响应内容或凭据的底层错误。
            throw ForumShareError.network
        }
        guard let http = response as? HTTPURLResponse,
              let finalURL = http.url, ShareRedirectPolicy.isAllowed(finalURL, host: link.host) else { throw ForumShareError.unsafeRedirect }
        lastHTTPStatus = http.statusCode
        let sample = String(decoding: data.prefix(65536), as: UTF8.self).lowercased()
        let looksLikeHTML = sample.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("<")
        if http.value(forHTTPHeaderField: "cf-mitigated")?.lowercased() == "challenge"
            || (looksLikeHTML && (sample.contains("cf-chl-") || sample.contains("/cdn-cgi/challenge-platform/")
                                 || sample.contains("just a moment"))) {
            throw ForumShareError.cloudflare
        }
        if http.statusCode == 429 { throw ForumShareError.rateLimited }
        let decoded = try? JSONSerialization.jsonObject(with: data)
        let object = decoded as? [String: Any]
        if let kind = object?["error_type"] as? String,
           kind == "not_logged_in" || kind == "login_required" { throw ForumShareError.loginRequired }
        if http.statusCode == 401 { throw ForumShareError.loginRequired }
        if http.statusCode == 403 {
            if looksLikeHTML && sample.contains("cloudflare") { throw ForumShareError.cloudflare }
            throw ForumShareError.accessDenied
        }
        if http.statusCode == 404 || http.statusCode == 410 { throw ForumShareError.unavailable }
        if (300..<400).contains(http.statusCode) {
            if http.value(forHTTPHeaderField: "Location")?.lowercased().contains("login") == true { throw ForumShareError.loginRequired }
            throw ForumShareError.unsafeRedirect
        }
        if finalURL.path.lowercased().contains("login") { throw ForumShareError.loginRequired }
        guard (200..<300).contains(http.statusCode) else { throw ForumShareError.network }
        guard let json = object else { throw ForumShareError.invalidResponse }
        if let kind = json["error_type"] as? String {
            if kind == "not_logged_in" || kind == "login_required" { throw ForumShareError.loginRequired }
            if kind == "rate_limit" { throw ForumShareError.rateLimited }
            if kind == "invalid_access" { throw ForumShareError.accessDenied }
            throw ForumShareError.invalidResponse
        }
        if json["errors"] != nil { throw ForumShareError.invalidResponse }
        return json
    }

    private func markdownText(_ value: String) -> String {
        var result = value.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
        for token in ["\\", "`", "*", "_", "[", "]", "<", ">", "#"] {
            result = result.replacingOccurrences(of: token, with: "\\" + token)
        }
        return result
    }
}

// 不依赖 WebKit 的 HTML 解析容错规则：仅重建允许的标签和属性，其他输入不会进入标签上下文。
private enum SafeShareHTML {
    private static let allowed: Set<String> = ["p", "div", "span", "a", "img", "pre", "code", "br", "hr", "strong", "em", "b", "i", "s", "del", "blockquote", "ul", "ol", "li", "h1", "h2", "h3", "h4", "h5", "h6", "table", "thead", "tbody", "tfoot", "tr", "th", "td", "details", "summary", "figure", "figcaption", "sup", "sub", "time", "abbr", "kbd", "mark", "small", "dl", "dt", "dd"]
    private static let void: Set<String> = ["img", "br", "hr"]
    private static let discardContent: Set<String> = ["script", "style", "iframe", "object", "svg", "math", "template", "noscript", "textarea", "title", "xmp", "plaintext", "select", "button", "video", "audio", "canvas"]

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    static func clean(_ html: String, baseURL: URL, imageScheme: String) -> String {
        var result = ""
        var cursor = html.startIndex
        var stack: [String] = []
        while cursor < html.endIndex {
            guard html[cursor] == "<" else {
                let end = html[cursor...].firstIndex(of: "<") ?? html.endIndex
                // 原始文本实体保留为文本，实体产生的尖括号不会被 HTML 再次解析为标签。
                result += html[cursor..<end].replacingOccurrences(of: ">", with: "&gt;")
                cursor = end
                continue
            }
            if html[cursor...].hasPrefix("<!--") {
                guard let end = html.range(of: "-->", range: cursor..<html.endIndex) else { break }
                cursor = end.upperBound
                continue
            }
            guard let end = tagEnd(html, from: cursor) else {
                result += "&lt;"
                cursor = html.index(after: cursor)
                continue
            }
            let token = String(html[html.index(after: cursor)..<end])
            cursor = html.index(after: end)
            let bytes = Array(token.utf8)
            var index = 0
            let closing = bytes.first == 47
            if closing { index += 1 }
            let begin = index
            while index < bytes.count && isName(bytes[index]) { index += 1 }
            guard index > begin else { continue }
            let name = String(decoding: bytes[begin..<index], as: UTF8.self).lowercased()
            guard index == bytes.count || isSpace(bytes[index]) || bytes[index] == 47 else { continue }
            if discardContent.contains(name) && !closing {
                guard let close = html.range(of: "</" + name, options: .caseInsensitive, range: cursor..<html.endIndex),
                      let closeEnd = tagEnd(html, from: close.lowerBound) else { break }
                cursor = html.index(after: closeEnd)
                continue
            }
            guard allowed.contains(name) else { continue }
            if closing {
                if let position = stack.lastIndex(of: name) {
                    for tag in stack[position...].reversed() { result += "</\(tag)>" }
                    stack.removeSubrange(position...)
                }
                continue
            }
            let attributes = parseAttributes(bytes, from: index)
            var output = "<" + name
            if let title = attributes["title"] { output += " title=\"\(escape(decodeEntities(title)))\"" }
            if name == "a", let href = attributes["href"], let url = absoluteURL(href, baseURL: baseURL, image: false) {
                output += " href=\"\(escape(url))\" rel=\"noreferrer noopener\""
            }
            if name == "img" {
                guard let src = attributes["src"], let url = absoluteURL(src, baseURL: baseURL, image: true),
                      var components = URLComponents(string: url) else { continue }
                components.scheme = imageScheme
                guard let imageURL = components.url else { continue }
                output += " src=\"\(escape(imageURL.absoluteString))\" referrerpolicy=\"no-referrer\""
                if let alt = attributes["alt"] { output += " alt=\"\(escape(decodeEntities(alt)))\"" }
            }
            if ["td", "th"].contains(name) {
                for key in ["colspan", "rowspan"] {
                    if let value = attributes[key], let number = Int(value), (1...100).contains(number) { output += " \(key)=\"\(number)\"" }
                }
            }
            if name == "ol", let value = attributes["start"], let number = Int(value) { output += " start=\"\(number)\"" }
            result += output + ">"
            if !void.contains(name) { stack.append(name) }
        }
        for tag in stack.reversed() { result += "</\(tag)>" }
        return result
    }

    private static func tagEnd(_ text: String, from start: String.Index) -> String.Index? {
        var quote: Character?
        var index = text.index(after: start)
        while index < text.endIndex {
            let character = text[index]
            if let current = quote {
                if character == current { quote = nil }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == ">" {
                return index
            }
            index = text.index(after: index)
        }
        return nil
    }

    private static func isName(_ byte: UInt8) -> Bool {
        (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122) || (byte >= 48 && byte <= 57)
    }

    private static func isSpace(_ byte: UInt8) -> Bool { byte == 32 || byte == 9 || byte == 10 || byte == 12 || byte == 13 }

    private static func parseAttributes(_ bytes: [UInt8], from start: Int) -> [String: String] {
        var attributes: [String: String] = [:]
        var index = start
        while index < bytes.count {
            while index < bytes.count && (isSpace(bytes[index]) || bytes[index] == 47) { index += 1 }
            let begin = index
            while index < bytes.count && !isSpace(bytes[index]) && bytes[index] != 61 && bytes[index] != 47 { index += 1 }
            guard index > begin else { index += 1; continue }
            let name = String(decoding: bytes[begin..<index], as: UTF8.self).lowercased()
            while index < bytes.count && isSpace(bytes[index]) { index += 1 }
            guard index < bytes.count && bytes[index] == 61 else { continue }
            index += 1
            while index < bytes.count && isSpace(bytes[index]) { index += 1 }
            guard index < bytes.count else { break }
            let quote = bytes[index] == 34 || bytes[index] == 39 ? bytes[index] : nil
            if quote != nil { index += 1 }
            let valueStart = index
            if let quote = quote {
                while index < bytes.count && bytes[index] != quote { index += 1 }
            } else {
                while index < bytes.count && !isSpace(bytes[index]) { index += 1 }
            }
            let value = String(decoding: bytes[valueStart..<index], as: UTF8.self)
            if attributes[name] == nil { attributes[name] = value }
            if quote != nil && index < bytes.count { index += 1 }
        }
        return attributes
    }

    private static func absoluteURL(_ value: String, baseURL: URL, image: Bool) -> String? {
        let decoded = decodeEntities(value).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !decoded.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              let url = URL(string: decoded, relativeTo: baseURL)?.absoluteURL,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(), scheme == "https" || (!image && scheme == "http"),
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil else { return nil }
        return url.absoluteString
    }

    private static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var result = ""
        var cursor = text.startIndex
        while cursor < text.endIndex {
            guard text[cursor] == "&", let end = text[cursor...].firstIndex(of: ";"),
                  text.distance(from: cursor, to: end) <= 12 else {
                result.append(text[cursor]); cursor = text.index(after: cursor); continue
            }
            let entity = String(text[text.index(after: cursor)..<end])
            let named = ["amp": "&", "quot": "\"", "apos": "'", "lt": "<", "gt": ">", "nbsp": " "]
            var decoded = named[entity]
            if entity.hasPrefix("#") {
                let hexadecimal = entity.hasPrefix("#x") || entity.hasPrefix("#X")
                let digits = entity.dropFirst(hexadecimal ? 2 : 1)
                if let number = UInt32(digits, radix: hexadecimal ? 16 : 10), let scalar = UnicodeScalar(number) { decoded = String(scalar) }
            }
            if let decoded = decoded { result += decoded; cursor = text.index(after: end) }
            else { result.append("&"); cursor = text.index(after: cursor) }
        }
        return result
    }
}
