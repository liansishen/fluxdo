import Foundation
import WebKit

/// 在原生层拦截 WKWebView 的 SSL challenge，绕过 Dart 方法通道延迟。
///
/// iOS 上 flutter_inappwebview 的 `onReceivedServerTrustAuthRequest` 回调
/// 需要经过 Dart 方法通道往返，延迟过高导致 TLS 握手失败。
/// 本类通过 swizzle 插件的 `webView(_:didReceive:completionHandler:)` 方法，
/// 在原生层直接完成代理 CA 证书的信任评估（微秒级），绕过 Dart 通道。
@objc class DohProxyCertHandler: NSObject {
    static let shared = DohProxyCertHandler()
    private static var isSwizzled = false
    private static var originalImp: IMP?

    /// 代理 CA 证书的 DER 数据（用于比对）
    private var caCertDerData: Data?
    /// SecCertificate 引用（用于 SecTrustSetAnchorCertificates）
    private var caCertRef: SecCertificate?

    /// 从 PEM 字符串加载代理 CA 证书，首次调用时执行 swizzle
    func setCaCertPem(_ pem: String) {
        let base64 = pem
            .components(separatedBy: "\n")
            .filter { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                return !trimmed.isEmpty && !trimmed.hasPrefix("-----")
            }
            .joined()
        guard let derData = Data(base64Encoded: base64),
              let certRef = SecCertificateCreateWithData(nil, derData as CFData) else {
            return
        }
        caCertDerData = derData
        caCertRef = certRef

        if !DohProxyCertHandler.isSwizzled {
            DohProxyCertHandler.isSwizzled = true
            performSwizzle()
        }
    }

    func clearCaCert() {
        caCertDerData = nil
        caCertRef = nil
    }

    // MARK: - Swizzle

    private func performSwizzle() {
        let selector = NSSelectorFromString(
            "webView:didReceiveAuthenticationChallenge:completionHandler:"
        )

        // 按名称查找 flutter_inappwebview 的 InAppWebView 类
        var targetClass: AnyClass?
        for name in [
            "flutter_inappwebview_ios.InAppWebView",
            "InAppWebView",
            "flutter_inappwebview.InAppWebView",
        ] {
            if let cls = NSClassFromString(name),
               class_getInstanceMethod(cls, selector) != nil {
                targetClass = cls
                break
            }
        }

        // 兜底：遍历所有 WKWebView 子类
        if targetClass == nil {
            var count: UInt32 = 0
            if let classes = objc_copyClassList(&count) {
                for i in 0..<Int(count) {
                    let cls: AnyClass = classes[i]
                    if cls is WKWebView.Type,
                       class_getInstanceMethod(cls, selector) != nil {
                        targetClass = cls
                        break
                    }
                }
            }
        }

        guard let cls = targetClass,
              let originalMethod = class_getInstanceMethod(cls, selector) else {
            return
        }

        DohProxyCertHandler.originalImp = method_getImplementation(originalMethod)
        let savedImp = DohProxyCertHandler.originalImp!
        let savedSelector = selector

        let block: @convention(block) (
            AnyObject,
            WKWebView,
            URLAuthenticationChallenge,
            @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
        ) -> Void = { obj, webView, challenge, completionHandler in
            guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
                  let serverTrust = challenge.protectionSpace.serverTrust,
                  let caCert = DohProxyCertHandler.shared.caCertRef else {
                // 非 ServerTrust 或无 CA → 走原始流程（Dart 方法通道）
                typealias F = @convention(c) (AnyObject, Selector, WKWebView, URLAuthenticationChallenge, @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) -> Void
                unsafeBitCast(savedImp, to: F.self)(obj, savedSelector, webView, challenge, completionHandler)
                return
            }

            // 将代理 CA 加入信任锚点并评估证书链
            SecTrustSetAnchorCertificates(serverTrust, [caCert] as CFArray)
            SecTrustSetAnchorCertificatesOnly(serverTrust, false)

            var error: CFError?
            if SecTrustEvaluateWithError(serverTrust, &error) {
                // 代理 CA 签发的证书 → 在后台线程设置信任并完成
                DispatchQueue.global().async {
                    let exceptions = SecTrustCopyExceptions(serverTrust)
                    SecTrustSetExceptions(serverTrust, exceptions)
                    let credential = URLCredential(trust: serverTrust)
                    completionHandler(.useCredential, credential)
                }
            } else {
                // 非代理证书（评估失败）→ 走原始流程
                typealias F = @convention(c) (AnyObject, Selector, WKWebView, URLAuthenticationChallenge, @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) -> Void
                unsafeBitCast(savedImp, to: F.self)(obj, savedSelector, webView, challenge, completionHandler)
            }
        }

        method_setImplementation(originalMethod, imp_implementationWithBlock(block))
    }
}
