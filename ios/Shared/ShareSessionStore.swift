import Foundation

struct ShareSession: Codable {
    let cookieHeader: String
    let userAgent: String
}

/// 这里只解析候选组；是否获准访问始终由系统容器接口决定。
enum ShareAppGroupResolver {
    static let originalGroup = "group.com.github.lingyan000.fluxdo"

    static func isAllowed(_ identifier: String) -> Bool {
        if identifier == originalGroup { return true }
        let prefix = originalGroup + "."
        guard identifier.hasPrefix(prefix) else { return false }
        let team = identifier.dropFirst(prefix.count).utf8
        return team.count == 10 && team.allSatisfy {
            (65...90).contains($0) || (48...57).contains($0)
        }
    }

    /// 描述文件是 CMS 包裹的 XML；不依赖私有接口，也不把解析结果当作系统授权。
    static func profileGroups(from data: Data) -> [String]? {
        let opening = Data("<?xml".utf8)
        let closing = Data("</plist>".utf8)
        guard let start = data.range(of: opening),
              let end = data.range(of: closing, in: start.lowerBound..<data.endIndex),
              let plist = try? PropertyListSerialization.propertyList(
                from: data[start.lowerBound..<end.upperBound], options: [], format: nil
              ) as? [String: Any],
              let entitlements = plist["Entitlements"] as? [String: Any]
        else { return nil }
        return entitlements["com.apple.security.application-groups"] as? [String]
    }

    static func resolve(profileData: Data?, altAppGroups: [String]?) -> String? {
        let groups: [String]
        if let profileData = profileData {
            // 有描述文件就只认它；损坏、缺组或未授权都不能回退到元数据。
            guard let profile = profileGroups(from: profileData) else { return nil }
            groups = profile
        } else if let altAppGroups = altAppGroups {
            groups = altAppGroups
        } else {
            // App Store 安装可能没有描述文件及侧载元数据，仍须系统授权原组。
            return originalGroup
        }
        let candidates = Set(groups.filter { isAllowed($0) })
        // 不依赖数组顺序选择，以免主应用与扩展写入不同容器。
        return candidates.count == 1 ? candidates.first : nil
    }
}

/// 主应用与分享扩展共用；凭据只保存在受保护的 App Group 私有文件中。
enum ShareSessionStore {
    private static let supportedHosts: Set<String> = ["linux.do", "idcflare.com"]
    private static let cookieNames: Set<String> = ["_t", "_forum_session", "cf_clearance"]
    private static let lock = NSLock()
    private static let resolvedGroupIdentifier: String? = {
        let bundle = Bundle.main
        if let url = bundle.url(forResource: "embedded", withExtension: "mobileprovision") {
            guard let profile = try? Data(contentsOf: url) else { return nil }
            return ShareAppGroupResolver.resolve(profileData: profile, altAppGroups: nil)
        }
        let metadata = bundle.object(forInfoDictionaryKey: "ALTAppGroups")
        return ShareAppGroupResolver.resolve(
            profileData: nil, altAppGroups: metadata.map { $0 as? [String] ?? [] }
        )
    }()


    private struct StoredSession: Codable {
        let cookieHeader: String
        let userAgent: String
        let cookieExpirations: [String: Double]
    }
    enum StoreError: LocalizedError {
        case unsupportedHost
        case unavailableGroup
        case missingSession
        case expiredSession
        case invalidSession
        case fileOperation(Int)

        var errorDescription: String? {
            switch self {
            case .unsupportedHost: return "分享会话的论坛域名不受支持。"
            case .unavailableGroup: return "无法访问分享 App Group，请检查主应用与扩展的签名及 App Groups 权限。"
            case .missingSession: return "尚未同步该论坛的分享会话，请先在主应用登录。"
            case .expiredSession: return "分享会话已过期，请在主应用刷新登录状态。"
            case .invalidSession: return "分享会话格式无效。"
            case .fileOperation(let code): return "分享会话文件操作失败（错误码 \(code)）。"
            }
        }
    }

    static func read(host: String) -> ShareSession? {
        try? readSession(host: host)
    }

    static func readSession(host: String) throws -> ShareSession {
        guard supportedHosts.contains(host) else { throw StoreError.unsupportedHost }
        lock.lock()
        defer { lock.unlock() }
        let data: Data
        do {
            let directory = try sessionDirectory()
            do {
                data = try Data(contentsOf: directory.appendingPathComponent("\(host).json"))
            } catch let error as NSError where error.domain == NSCocoaErrorDomain
                && error.code == NSFileReadNoSuchFileError {
                throw StoreError.missingSession
            }
        } catch let error as StoreError {
            throw error
        } catch {
            throw StoreError.fileOperation((error as NSError).code)
        }
        return try decodeSession(data, now: Date().timeIntervalSince1970 * 1000)
    }

    /// 解码与有效期过滤不访问容器，供原生回归验证同一套生产行为。
    static func decodeSession(_ data: Data, now: Double) throws -> ShareSession {
        guard let stored = try? JSONDecoder().decode(StoredSession.self, from: data),
              !stored.cookieHeader.isEmpty,
              valid(ShareSession(cookieHeader: stored.cookieHeader, userAgent: stored.userAgent)),
              stored.cookieExpirations.allSatisfy({ cookieNames.contains($0.key) && $0.value.isFinite })
        else { throw StoreError.invalidSession }
        let header = stored.cookieHeader.components(separatedBy: "; ").filter { pair in
            guard let separator = pair.firstIndex(of: "=") else { return false }
            let name = String(pair[..<separator])
            guard let expiration = stored.cookieExpirations[name] else { return true }
            return expiration > now
        }.joined(separator: "; ")
        guard !header.isEmpty else { throw StoreError.expiredSession }
        return ShareSession(cookieHeader: header, userAgent: stored.userAgent)
    }
    /// 空 Cookie 表示删除该站凭据，不影响另一个论坛。
    static func write(host: String, cookieHeader: String, userAgent: String,
                      cookieExpirations: [String: Double] = [:]) throws {
        guard supportedHosts.contains(host) else { throw StoreError.unsupportedHost }
        let session = ShareSession(cookieHeader: cookieHeader, userAgent: userAgent)
        guard valid(session) else { throw StoreError.invalidSession }
        guard cookieExpirations.allSatisfy({ cookieNames.contains($0.key) && $0.value.isFinite })
        else { throw StoreError.invalidSession }
        lock.lock()
        defer { lock.unlock() }
        do {
            let directory = try sessionDirectory()
            let file = directory.appendingPathComponent("\(host).json")
            if cookieHeader.isEmpty {
                if FileManager.default.fileExists(atPath: file.path) {
                    try FileManager.default.removeItem(at: file)
                }
                return
            }
            let stored = StoredSession(cookieHeader: cookieHeader, userAgent: userAgent,
                                       cookieExpirations: cookieExpirations)
            let data = try JSONEncoder().encode(stored)
            #if os(iOS)
            try data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            #else
            try data.write(to: file, options: .atomic)
            #endif
            var attributes: [FileAttributeKey: Any] = [.posixPermissions: 0o600]
            #if os(iOS)
            attributes[.protectionKey] = FileProtectionType.completeUntilFirstUserAuthentication
            #endif
            try FileManager.default.setAttributes(attributes, ofItemAtPath: file.path)
            var protectedFile = file
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try protectedFile.setResourceValues(values)
        } catch let error as StoreError {
            throw error
        } catch {
            // 不把底层异常中的路径或凭据交给日志。
            throw StoreError.fileOperation((error as NSError).code)
        }
    }

    private static func sessionDirectory() throws -> URL {
        guard let identifier = resolvedGroupIdentifier,
              let group = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: identifier
              ) else { throw StoreError.unavailableGroup }
        var directory = group.appendingPathComponent("ShareSessions", isDirectory: true)
        var attributes: [FileAttributeKey: Any] = [.posixPermissions: 0o700]
        #if os(iOS)
        attributes[.protectionKey] = FileProtectionType.completeUntilFirstUserAuthentication
        #endif
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: attributes)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try directory.setResourceValues(values)
        return directory
    }

    private static func valid(_ session: ShareSession) -> Bool {
        if session.cookieHeader.isEmpty { return true }
        guard !session.userAgent.isEmpty,
              session.userAgent.utf8.count <= 4096,
              session.cookieHeader.utf8.count <= 65536,
              !session.userAgent.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 })
        else { return false }
        var seen = Set<String>()
        for pair in session.cookieHeader.components(separatedBy: "; ") {
            guard let separator = pair.firstIndex(of: "=") else { return false }
            let name = String(pair[..<separator])
            let value = pair[pair.index(after: separator)...]
            guard cookieNames.contains(name), seen.insert(name).inserted,
                  !value.isEmpty,
                  value.unicodeScalars.allSatisfy({
                      $0.value >= 33 && $0.value <= 126 && $0.value != 59
                  }) else { return false }
        }
        return !seen.isEmpty
    }
}
