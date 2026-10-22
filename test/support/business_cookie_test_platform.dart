import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/network/cookie/cookie_jar_service.dart';

/// 业务会话测试使用的隔离 Cookie 存储，不读取本机浏览器。
class BusinessTestPlatform extends InAppWebViewPlatform {
  final cookies = BusinessTestCookieManager();

  Future<void> initialize({required String cookieDirectory}) async {
    InAppWebViewPlatform.instance = this;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (_) async => cookieDirectory,
        );
    await CookieJarService().initialize();
  }

  Future<void> reset() async {
    cookies.values = [];
    await CookieJarService().cookieJar.deleteAll();
  }

  @override
  PlatformCookieManager createPlatformCookieManager(
    PlatformCookieManagerCreationParams params,
  ) => cookies;
}

class BusinessTestCookieManager extends PlatformCookieManager {
  BusinessTestCookieManager()
    : super.implementation(const PlatformCookieManagerCreationParams());

  List<Cookie> values = [];

  Future<List<Cookie>> snapshot() async =>
      [...values];

  @override
  Future<Cookie?> getCookie({
    required WebUri url,
    required String name,
    PlatformInAppWebViewController? iosBelow11WebViewController,
    PlatformInAppWebViewController? webViewController,
  }) async {
    for (final cookie in values) {
      if (cookie.name == name) return cookie;
    }
    return null;
  }

  @override
  Future<List<Cookie>> getCookies({
    required WebUri url,
    PlatformInAppWebViewController? iosBelow11WebViewController,
    PlatformInAppWebViewController? webViewController,
  }) => snapshot();

  @override
  Future<List<Cookie>> getAllCookies() => snapshot();

  @override
  Future<bool> deleteCookie({
    required WebUri url,
    required String name,
    String path = '/',
    String? domain,
    PlatformInAppWebViewController? iosBelow11WebViewController,
    PlatformInAppWebViewController? webViewController,
  }) async {
    values.removeWhere((cookie) => cookie.name == name);
    return true;
  }
}

