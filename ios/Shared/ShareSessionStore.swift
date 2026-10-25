import Foundation

struct ShareSession: Codable {
    let cookieHeader: String
    let userAgent: String
}

/// 主应用与分享扩展共用；凭据只保存在受保护的 App Group 私有文件中。
enum ShareSessionStore {
    static let groupIdentifier = "group.com.github.lingyan000.fluxdo"
    private static let supportedHosts: Set<String> = ["linux.do", "idcflare.com"]
    private static let cookieNames: Set<String> = ["_t", "_forum_session", "cf_clearance"]
    private static let lock = NSLock()


    private struct StoredSession: Codable {
        let cookieHeader: String
        let userAgent: String
        let cookieExpirations: [String: Double]
    }
    enum StoreError: LocalizedError {
        case unsupportedHost
        case unavailableGroup
        case invalidSession
        case fileOperation(Int)

        var errorDescription: String? {
            switch self {
            case .unsupportedHost: return "分享会话的论坛域名不受支持。"
            case .unavailableGroup: return "无法访问分享 App Group，请检查主应用与扩展的签名及 App Groups 权限。"
            case .invalidSession: return "分享会话格式无效。"
            case .fileOperation(let code): return "分享会话文件操作失败（错误码 \(code)）。"
            }
        }
    }

    static func read(host: String) -> ShareSession? {
        lock.lock()
        defer { lock.unlock() }
        guard supportedHosts.contains(host),
              let directory = try? sessionDirectory(),
              let data = try? Data(contentsOf: directory.appendingPathComponent("\(host).json")),
              let stored = try? JSONDecoder().decode(StoredSession.self, from: data),
              valid(ShareSession(cookieHeader: stored.cookieHeader, userAgent: stored.userAgent))
        else { return nil }
        let now = Date().timeIntervalSince1970 * 1000
        let header = stored.cookieHeader.components(separatedBy: "; ").filter { pair in
            guard let separator = pair.firstIndex(of: "=") else { return false }
            let name = String(pair[..<separator])
            guard let expiration = stored.cookieExpirations[name] else { return true }
            return expiration.isFinite && expiration > now
        }.joined(separator: "; ")
        return header.isEmpty ? nil : ShareSession(cookieHeader: header, userAgent: stored.userAgent)
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
        guard let group = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: groupIdentifier
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
