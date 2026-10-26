import Foundation

/// 分享卡片文档：375 逻辑像素宽。经典版式与墨笺版式共用一份 HTML，
/// 切换主题只改根节点 data-theme 与 CSS 变量，不重建正文图片地址。
struct ShareImageDocument {
    let palette: ShareImagePalette

    init(palette: ShareImagePalette = .classic) {
        self.palette = palette
    }

    func html(topic: SharedTopic, post: SharedPost) -> String {
        ShareImageDocument.html(topic: topic, post: post, palette: palette)
    }

    static func html(topic: SharedTopic, post: SharedPost,
                     palette: ShareImagePalette = .classic) -> String {
        let created = TimeUtils.parseUtcTime(post.createdAt)
        let relative = SafeShareHTML.escape(TimeUtils.formatRelativeTime(created))
        let shortDate = SafeShareHTML.escape(TimeUtils.formatShortDate(created))
        let title = SafeShareHTML.escape(topic.title.isEmpty ? "话题" : topic.title)
        let display = SafeShareHTML.escape(displayName(post))
        let username = SafeShareHTML.escape(post.username)
        let site = SafeShareHTML.escape(siteName(topic.url))
        let source = SafeShareHTML.escape(sourceLink(topic: topic, post: post))
        let content = SafeShareHTML.clean(post.cooked, baseURL: topic.url,
                                          imageScheme: "fluxdo-share-image")
        let avatar = avatarHTML(post, topic: topic)
        let brandDate = shortDate.isEmpty ? "" : "<span class=\"brand-date\">\(shortDate)</span>"
        let classicMeta = "@\(username)" + (relative.isEmpty ? "" : " · \(relative)")
        let mojianMeta = relative.isEmpty ? "" : " · \(relative)"

        return """
        <!doctype html>
        <html lang="zh-CN" id="share-card" data-theme="\(palette.themeKey)">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'none'; style-src 'unsafe-inline'; img-src fluxdo-share-image:; frame-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'; connect-src 'none'; media-src 'none'">
        <meta name="referrer" content="no-referrer">
        <title>\(title)</title>
        <style>
        \(ShareImagePalette.css)
        </style>
        </head>
        <body>
        <div class="dual-rule"><div class="dual-thick"></div><div class="dual-thin"></div></div>
        <header class="brand">
        \(logoSVG)
        <span class="brand-name">\(site)</span>
        \(brandDate)
        </header>
        <h1 class="title">\(title)</h1>
        <div class="author">
        \(avatar)
        <div class="author-text"><span class="display-name">\(display)</span><span class="meta-classic">\(classicMeta)</span><span class="meta-mojian">\(mojianMeta)</span></div>
        </div>
        <div class="rule rule-top"></div>
        <section class="content">\(content)</section>
        <div class="rule rule-bottom"></div>
        <footer class="source">\(linkIconSVG)<a href="\(source)" rel="noreferrer noopener">\(source)</a></footer>
        </body>
        </html>
        """
    }

    // MARK: - 片段

    private static func displayName(_ post: SharedPost) -> String {
        if let name = post.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            return name
        }
        return post.username
    }

    private static func siteName(_ url: URL) -> String {
        let host = (url.host ?? "").lowercased()
        if host == "linux.do" || host.hasSuffix(".linux.do") { return "LINUX DO" }
        if host == "idcflare.com" || host.hasSuffix(".idcflare.com") { return "IDCFLARE" }
        return host.uppercased()
    }

    private static func sourceLink(topic: SharedTopic, post: SharedPost) -> String {
        let host = topic.url.host ?? ""
        let slug = topic.slug.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        if host.isEmpty || slug.isEmpty {
            var base = topic.url.absoluteString
            while base.hasSuffix("/") { base.removeLast() }
            return "\(base)/\(post.postNumber)"
        }
        let encoded = slug.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? slug
        return "https://\(host)/t/\(encoded)/\(topic.id)/\(post.postNumber)"
    }

    private static func avatarHTML(_ post: SharedPost, topic: SharedTopic) -> String {
        if let template = post.avatarTemplate, !template.isEmpty,
           let source = avatarSource(template, baseURL: topic.url) {
            return "<img class=\"avatar\" src=\"\(SafeShareHTML.escape(source))\" alt=\"\">"
        }
        let initial = String(displayName(post).prefix(1)).uppercased()
        let label = SafeShareHTML.escape(initial.isEmpty ? "?" : initial)
        return "<div class=\"avatar avatar-fallback\" aria-hidden=\"true\"><span>\(label)</span></div>"
    }

    private static func avatarSource(_ template: String, baseURL: URL) -> String? {
        let sized = template.replacingOccurrences(of: "{size}", with: "120")
        guard let absolute = URL(string: sized, relativeTo: baseURL)?.absoluteURL,
              var components = URLComponents(url: absolute, resolvingAgainstBaseURL: false),
              let host = components.host, !host.isEmpty else { return nil }
        components.scheme = "fluxdo-share-image"
        return components.url?.absoluteString
    }

    // MARK: - 内嵌素材

    private static let logoSVG = """
    <svg class="logo" viewBox="0 0 1024 1024" width="28" height="28" aria-hidden="true" focusable="false">
    <defs><mask id="fluxdo-logo-mask" maskUnits="userSpaceOnUse" x="91" y="91" width="842" height="842"><circle cx="512" cy="512" r="421" fill="#FFFFFF"/></mask></defs>
    <circle cx="512" cy="512" r="448" fill="#F0F0F0"/>
    <g mask="url(#fluxdo-logo-mask)">
    <rect x="91" y="700" width="842" height="233" fill="#FFB003"/>
    <rect x="91" y="324" width="842" height="376" fill="#F0F0F0"/>
    <rect x="91" y="91" width="842" height="233" fill="#1C1C1E"/>
    </g>
    </svg>
    """

    private static let linkIconSVG = """
    <svg viewBox="0 0 24 24" width="14" height="14" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true" focusable="false"><path d="M10.6 13.4a4 4 0 0 0 5.7 0l2.3-2.3a4 4 0 0 0-5.7-5.7l-1.3 1.3"/><path d="M13.4 10.6a4 4 0 0 0-5.7 0l-2.3 2.3a4 4 0 0 0 5.7 5.7l1.3-1.3"/></svg>
    """
}

/// 扩展不加载 Dart 引擎，原生时间工具沿用主应用的 UTC 解析与本地显示约定。
private enum TimeUtils {
    static func parseUtcTime(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: raw) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: raw)
    }

    /// 与 TimeUtils.formatRelativeTime 的分档保持一致。
    static func formatRelativeTime(_ date: Date?) -> String {
        guard let date else { return "" }
        let seconds = max(0, Date().timeIntervalSince(date))
        if seconds < 60 { return "刚刚" }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(minutes)分钟前" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)小时前" }
        let days = hours / 24
        if days < 7 { return "\(days)天前" }
        if days < 30 { return "\(days / 7)周前" }
        if days < 365 { return "\(days / 30)个月前" }
        return "\(days / 365)年前"
    }

    /// 与 TimeUtils.formatShortDate 的“1月15日”一致。
    static func formatShortDate(_ date: Date?) -> String {
        guard let date else { return "" }
        let parts = Calendar.current.dateComponents([.month, .day], from: date)
        guard let month = parts.month, let day = parts.day else { return "" }
        return "\(month)月\(day)日"
    }

}

/// 七套分享图配色。颜色统一用十六进制字符串，选中控件可自行转 UIColor。
enum ShareImagePalette: Int, CaseIterable {
    case classic
    case light
    case dark
    case black
    case blue
    case green
    case mojian

    var name: String {
        switch self {
        case .classic: return "经典"
        case .light: return "纯白"
        case .dark: return "深色"
        case .black: return "纯黑"
        case .blue: return "蓝调"
        case .green: return "绿野"
        case .mojian: return "墨笺"
        }
    }

    var themeKey: String {
        switch self {
        case .classic: return "classic"
        case .light: return "light"
        case .dark: return "dark"
        case .black: return "black"
        case .blue: return "blue"
        case .green: return "green"
        case .mojian: return "mojian"
        }
    }

    /// 页面底色。
    var background: String {
        switch self {
        case .classic: return "#F9F1E4"
        case .light: return "#FFFFFF"
        case .dark: return "#1E1E1E"
        case .black: return "#000000"
        case .blue: return "#E8F4FC"
        case .green: return "#E8F5E9"
        case .mojian: return "#F6F2EA"
        }
    }

    /// 内容卡片底色；墨笺版式实际不使用卡片。
    var card: String {
        switch self {
        case .classic: return "#FFFFFF"
        case .light: return "#F5F5F5"
        case .dark: return "#2D2D2D"
        case .black: return "#1A1A1A"
        case .blue: return "#FFFFFF"
        case .green: return "#FFFFFF"
        case .mojian: return "#FBF8F2"
        }
    }

    var isDark: Bool {
        switch self {
        case .dark, .black: return true
        default: return false
        }
    }

    var text: String {
        switch self {
        case .classic, .light, .blue, .green: return "#000000"
        case .dark, .black: return "#FFFFFF"
        case .mojian: return "#2E2A25"
        }
    }

    var strongText: String {
        switch self {
        case .classic, .light, .blue, .green: return "#111111"
        case .dark, .black: return "#FFFFFF"
        case .mojian: return "#1D1B18"
        }
    }

    var secondaryText: String {
        switch self {
        case .classic: return "#64605B"
        case .light: return "#666666"
        case .dark: return "#A5A5A5"
        case .black: return "#999999"
        case .blue: return "#5D6265"
        case .green: return "#5D625D"
        case .mojian: return "#68615A"
        }
    }

    var border: String {
        switch self {
        case .classic: return "#E0D9CD"
        case .light: return "#E6E6E6"
        case .dark: return "#353535"
        case .black: return "#2A2A2A"
        case .blue: return "#D1DCE3"
        case .green: return "#D1DDD2"
        case .mojian: return "#E3DBCD"
        }
    }

    var accent: String {
        switch self {
        case .classic, .light, .blue: return "#1769AA"
        case .dark, .black: return "#6CB6FF"
        case .green: return "#2E7D32"
        case .mojian: return "#B23A26"
        }
    }

    var codeBackground: String {
        switch self {
        case .classic: return "#F2ECE1"
        case .light: return "#F2F2F2"
        case .dark: return "#242424"
        case .black: return "#161616"
        case .blue: return "#EFF7FD"
        case .green: return "#F0F8F0"
        case .mojian: return "#EEE8DC"
        }
    }

    var inlineCodeBackground: String {
        switch self {
        case .classic: return "#EFE8DC"
        case .light: return "#EDEDED"
        case .dark: return "#3A3A3A"
        case .black: return "#2A2A2A"
        case .blue: return "#DDEBF5"
        case .green: return "#DDEFDD"
        case .mojian: return "#EEE8DC"
        }
    }

    var avatarBackground: String {
        switch self {
        case .classic: return "#E0E0E0"
        case .light: return "#E8E8E8"
        case .dark: return "#3A3A3A"
        case .black: return "#262626"
        case .blue: return "#DCEAF4"
        case .green: return "#DCEEDD"
        case .mojian: return "#EEE8DC"
        }
    }

    var quoteLine: String {
        switch self {
        case .classic: return "#D8D0C3"
        case .light: return "#D9D9D9"
        case .dark: return "#555555"
        case .black: return "#444444"
        case .blue: return "#B9D4E6"
        case .green: return "#BBD8BC"
        case .mojian: return "#CDC3B1"
        }
    }

    private var variables: [(key: String, value: String)] {
        [
            ("--bg", background),
            ("--card", card),
            ("--text", text),
            ("--strong", strongText),
            ("--secondary", secondaryText),
            ("--border", border),
            ("--accent", accent),
            ("--code-bg", codeBackground),
            ("--inline-code-bg", inlineCodeBackground),
            ("--avatar-bg", avatarBackground),
            ("--quote-line", quoteLine),
        ]
    }

    var variableDeclarations: String {
        variables.map { "\($0.key):\($0.value);" }.joined()
    }

    /// 运行时切主题：只写 data-theme 和 CSS 变量，图片 src 不变，因此不会重新下载。
    static func themeUpdateScript(_ palette: ShareImagePalette) -> String {
        let assignments = palette.variables
            .map { "root.style.setProperty('\($0.key)','\($0.value)');" }
            .joined()
        return "(function(){var root=document.documentElement;"
            + "root.setAttribute('data-theme','\(palette.themeKey)');"
            + assignments
            + "return '\(palette.themeKey)';})()"
    }

    /// 七套配色的 CSS 变量与墨笺版式覆盖规则。
    static var css: String {
        let themes = allCases
            .map { "html[data-theme=\"\($0.themeKey)\"]{\($0.variableDeclarations)}" }
            .joined(separator: "\n")
        return baseCSS + "\n" + themes + "\n" + mojianCSS
    }

    private static let baseCSS = #"""
    :root{--serif:"Songti SC","STSong","Noto Serif SC","Source Han Serif SC",serif}
    *{box-sizing:border-box}
    html,body{margin:0;padding:0}
    html{background:var(--bg)}
    body{width:375px;margin:0;padding:20px;background:var(--bg);color:var(--text);font:400 15px/1.7 -apple-system,BlinkMacSystemFont,"PingFang SC","Hiragino Sans GB","Microsoft YaHei",sans-serif;overflow-wrap:break-word;-webkit-text-size-adjust:100%}
    .dual-rule{display:none}
    .dual-thick{display:block;height:1.5px;background:#1D1B18;margin-bottom:3px}
    .dual-thin{display:block;height:.6px;background:#CDC3B1}
    .brand{display:flex;align-items:center;gap:8px;min-height:28px}
    .logo{display:block;width:28px;height:28px;flex:none}
    .brand-name{font-size:16px;font-weight:600;line-height:1.2;color:var(--strong);opacity:.8;white-space:nowrap}
    .brand-date{display:none;margin-left:auto;font-size:12px;line-height:1.4;color:var(--secondary);white-space:nowrap}
    .title{margin:16px 0 12px;font-size:16px;line-height:1.4;font-weight:600;color:var(--strong);overflow-wrap:anywhere}
    .author{display:flex;align-items:center;gap:10px;min-width:0}
    .avatar{display:flex;align-items:center;justify-content:center;width:36px;height:36px;border:1px solid var(--border);border-radius:50%;background:var(--avatar-bg);color:var(--secondary);font-size:14px;font-weight:600;object-fit:cover;flex:none;overflow:hidden}
    .avatar-fallback span{line-height:1}
    .author-text{display:flex;flex-direction:column;flex:1;min-width:0}
    .display-name{display:block;font-size:14px;font-weight:500;line-height:1.45;color:var(--strong);white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
    .meta-classic{display:block;font-size:12px;line-height:1.45;color:var(--secondary);white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
    .meta-mojian{display:none}
    .rule{height:1px;background:var(--border);border:0}
    .rule-top{margin:12px 0}
    .rule-bottom{margin:16px 0 12px}
    .content{background:var(--card);border-radius:8px;padding:12px;min-width:0;color:var(--text);overflow-wrap:break-word}
    .content>:first-child{margin-top:0}
    .content>:last-child{margin-bottom:0}
    .content p{margin:0 0 .8em}
    .content h1,.content h2,.content h3,.content h4,.content h5,.content h6{margin:1em 0 .5em;font-weight:600;line-height:1.4;color:var(--strong)}
    .content h1{font-size:1.35em}
    .content h2{font-size:1.25em}
    .content h3{font-size:1.15em}
    .content h4,.content h5,.content h6{font-size:1.05em}
    .content a{color:var(--accent);text-decoration:none;overflow-wrap:anywhere}
    .content img{max-width:100%;height:auto;border-radius:4px;vertical-align:middle}
    .content img[src*="emoji"],.content img[title^=":"]{width:20px;height:20px;display:inline-block;margin:0 2px;vertical-align:-4px;border-radius:0}
    .content pre{margin:0 0 .8em;padding:10px;background:var(--code-bg);border-radius:6px;white-space:pre-wrap;overflow-wrap:anywhere;word-break:break-word;overflow:visible;max-width:100%}
    .content code,.content kbd,.content samp{font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;font-size:12.5px;overflow-wrap:anywhere;word-break:break-word}
    .content code{padding:1px 4px;background:var(--inline-code-bg);border-radius:3px}
    .content pre code{display:block;padding:0;background:transparent;border-radius:0;font-size:12px;line-height:1.5;white-space:pre-wrap;overflow-wrap:anywhere;word-break:break-word}
    .content blockquote{margin:0 0 .8em;padding:2px 0 2px 12px;border-left:3px solid var(--quote-line);color:var(--secondary)}
    .content ul,.content ol{margin:0 0 .8em;padding-left:1.5em}
    .content li{margin:.2em 0;overflow-wrap:anywhere}
    .content table{display:table;width:100%;table-layout:fixed;border-collapse:collapse;margin:0 0 .8em}
    .content th,.content td{padding:6px;border:1px solid var(--border);text-align:left;vertical-align:top;overflow-wrap:anywhere;word-break:break-word}
    .content th{background:var(--code-bg);font-weight:600}
    .content hr{margin:1em 0;border:0;border-top:1px solid var(--border)}
    .content details,.content figure{margin:0 0 .8em}
    .content summary{cursor:default}
    .content figcaption{font-size:12px;color:var(--secondary)}
    .source{display:flex;align-items:center;gap:6px;min-width:0;font-size:11px;line-height:1.4;color:var(--secondary)}
    .source svg{display:block;width:14px;height:14px;flex:none}
    .source a{min-width:0;color:inherit;text-decoration:none;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
    """#

    private static let mojianCSS = #"""
    html[data-theme="mojian"] body{padding:20px 22px 18px;font-size:15px;line-height:1.7}
    html[data-theme="mojian"] .dual-rule{display:block;margin:0 0 10px}
    html[data-theme="mojian"] .brand{min-height:18px;gap:8px}
    html[data-theme="mojian"] .logo{width:18px;height:18px}
    html[data-theme="mojian"] .brand-name{font-family:var(--serif);font-size:12.5px;font-weight:600;letter-spacing:2.4px;color:#4A453E;opacity:1}
    html[data-theme="mojian"] .brand-date{display:block}
    html[data-theme="mojian"] .title{margin:18px 0 12px;font-family:var(--serif);font-size:21px;line-height:1.42;font-weight:700;letter-spacing:.3px;color:#1D1B18}
    html[data-theme="mojian"] .author{gap:8px}
    html[data-theme="mojian"] .avatar{width:20px;height:20px;border-radius:10px;font-size:10px}
    html[data-theme="mojian"] .author-text{display:block;flex:1;min-width:0;font-size:12.5px;line-height:1.4;color:#68615A;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
    html[data-theme="mojian"] .display-name{display:inline;font-size:12.5px;font-weight:400;color:#4A453E;white-space:nowrap;overflow:visible}
    html[data-theme="mojian"] .meta-classic{display:none}
    html[data-theme="mojian"] .meta-mojian{display:inline}
    html[data-theme="mojian"] .rule{height:.6px;background:var(--border)}
    html[data-theme="mojian"] .rule-top{margin:14px 0}
    html[data-theme="mojian"] .rule-bottom{margin:18px 0 10px}
    html[data-theme="mojian"] .content{padding:0;background:transparent;border-radius:0;font-family:var(--serif);font-size:15.5px;line-height:1.85;color:#2E2A25}
    html[data-theme="mojian"] .source{color:#68615A;font-size:11px}
    """#
}
