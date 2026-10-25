import 'dart:async';

import 'package:cookie_jar/cookie_jar.dart';
import 'package:dio/dio.dart';
import 'package:enhanced_cookie_jar/enhanced_cookie_jar.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../constants.dart';
import 'network/cookie/app_cookie_manager.dart';
import 'network/cookie/cookie_value_codec.dart';

/// iOS 分享扩展的单站会话副本；失败不影响 CookieJar 与登录流程。
///
/// EnhancedPersistCookieJar 没有变更流，下面的子类在所有中央写入口完成后
/// 通知同步，包括直接由 Dio、WebView/CDP 和会话规范化调用的 jar 方法。
final class ShareExtensionSessionService {
  ShareExtensionSessionService({required this.host});

  final String host;
  static const _channel = MethodChannel('fluxdo/share_extension');
  static const _names = ['_t', '_forum_session', 'cf_clearance'];
  CookieJar? _jar;
  Future<void> _serial = Future.value();
  int _revision = 0;
  int _logoutDepth = 0;
  String? _lastHeader;
  String? _lastUserAgent;
  Map<String, double> _lastExpirations = const {};
  bool _failureLogged = false;

  EnhancedPersistCookieJar persistentJar(FileCookieStore store) =>
      _SharingPersistCookieJar(store: store, onChanged: _changed);

  CookieJar memoryJar() => _SharingMemoryCookieJar(_changed);

  void start(CookieJar jar) {
    _jar = jar;
    _changed();
  }

  void _changed() {
    if (_jar == null || _logoutDepth > 0) return;
    unawaited(_enqueue(clear: false));
  }

  /// 先使旧快照失效，再串行删除共享文件；期间 WebView 清理通知不能回灌。
  Future<void> beginLogout() {
    _logoutDepth++;
    return _enqueue(clear: true);
  }

  void endLogout() {
    _logoutDepth--;
  }

  Future<void> _enqueue({required bool clear}) {
    final revision = ++_revision;
    final operation = _serial.then((_) async {
      if (revision != _revision) return;
      try {
        if (host != 'linux.do' && host != 'idcflare.com') return;
        var header = '';
        var userAgent = '';
        var expirations = <String, double>{};
        if (!clear) {
          final jar = _jar;
          if (jar == null) return;
          // 复用真正网络请求的 root 路径、过期过滤和同名 Cookie 选优，
          // 而不是另起一套可能挑中旧 cf_clearance 的选择规则。
          final networkHeader = await AppCookieManager(jar)
              .loadCookies(RequestOptions(path: 'https://$host/'));
          final selected = <String, String>{};
          for (final pair in networkHeader.split('; ')) {
            final separator = pair.indexOf('=');
            if (separator <= 0) continue;
            final name = pair.substring(0, separator);
            final value = pair.substring(separator + 1);
            if (_names.contains(name) && value.isNotEmpty && value != 'del') {
              selected[name] = pair;
            }
          }
          header = _names
              .where(selected.containsKey)
              .map((name) => selected[name]!)
              .join('; ');
          expirations = await _cookieExpirations(jar, selected);
          if (header.isNotEmpty) {
            userAgent = await AppConstants.getUserAgent();
          }
        }
        // 读取磁盘、解析 Cookie 或等待 UA 时可能已经退出或发生新变化。
        if (revision != _revision) return;
        if (header == _lastHeader &&
            userAgent == _lastUserAgent &&
            mapEquals(expirations, _lastExpirations)) {
          return;
        }
        await _channel.invokeMethod<void>('syncSession', {
          'host': host,
          'cookieHeader': header,
          'userAgent': userAgent,
          'cookieExpirations': expirations,
        });
        _lastHeader = header;
        _lastUserAgent = userAgent;
        _lastExpirations = expirations;
        _failureLogged = false;
      } on PlatformException catch (error) {
        // 不输出原生异常 message/details，避免底层错误携带凭据。
        final reason = error.code == 'SHARE_SESSION_UNAVAILABLE'
            ? 'App Group 不可用，请检查签名与权限'
            : '原生会话写入失败';
        _logFailure(reason);
      } on MissingPluginException {
        // 后台 isolate 没有注册通道时，留待主 isolate 恢复前台后重载同步。
        _logFailure('会话同步通道不可用');
      } catch (_) {
        _logFailure('会话同步失败，CookieJar 登录状态不受影响');
      }
    });
    _serial = operation;
    return operation;
  }

  void _logFailure(String reason) {
    if (_failureLogged) return;
    _failureLogged = true;
    debugPrint('[ShareExtension] $reason');
  }

  Future<Map<String, double>> _cookieExpirations(
    CookieJar jar,
    Map<String, String> selected,
  ) async {
    final uri = Uri(scheme: 'https', host: host, path: '/');
    final expirations = <String, double>{};
    void record(String name, String value, DateTime? expiry) {
      if (selected[name] != '$name=${CookieValueCodec.decode(value)}' ||
          expiry == null) {
        return;
      }
      final milliseconds = expiry.millisecondsSinceEpoch.toDouble();
      final previous = expirations[name];
      if (previous == null || milliseconds < previous) {
        expirations[name] = milliseconds;
      }
    }

    if (jar is EnhancedPersistCookieJar) {
      for (final cookie in await jar.loadCanonicalForRequest(uri)) {
        final expiry = cookie.maxAge == null
            ? cookie.expiresAt
            : cookie.creationTime.add(Duration(seconds: cookie.maxAge!));
        record(cookie.name, cookie.value, expiry);
      }
    } else {
      for (final cookie in await jar.loadForRequest(uri)) {
        record(
          cookie.name,
          cookie.value,
          jar is _SharingMemoryCookieJar
              ? jar.expirationFor(cookie)
              : cookie.expires,
        );
      }
    }
    return expirations;
  }
}

/// 覆盖公开写入口，保留 EnhancedPersistCookieJar 类型判断及其写入串行锁。
final class _SharingPersistCookieJar extends EnhancedPersistCookieJar {
  _SharingPersistCookieJar({required super.store, required this.onChanged});

  final void Function() onChanged;

  @override
  Future<void> saveCanonicalCookies(
    Uri uri,
    List<CanonicalCookie> cookies, {
    bool trusted = false,
  }) async {
    try {
      await super.saveCanonicalCookies(uri, cookies, trusted: trusted);
    } finally {
      onChanged();
    }
  }

  @override
  Future<void> delete(Uri uri, [bool withDomainSharedCookie = false]) async {
    try {
      await super.delete(uri, withDomainSharedCookie);
    } finally {
      onChanged();
    }
  }

  @override
  Future<int> deleteByName(Uri uri, String name) async {
    try {
      return await super.deleteByName(uri, name);
    } finally {
      onChanged();
    }
  }

  @override
  Future<int> replaceByNameForSite(
    Uri uri,
    String name,
    List<CanonicalCookie> replacements,
  ) async {
    try {
      return await super.replaceByNameForSite(uri, name, replacements);
    } finally {
      onChanged();
    }
  }

  @override
  Future<void> deleteAll() async {
    try {
      await super.deleteAll();
    } finally {
      onChanged();
    }
  }

  @override
  Future<void> reloadPersistedCookies() async {
    try {
      await super.reloadPersistedCookies();
    } finally {
      onChanged();
    }
  }
}

/// 持久存储初始化失败时，内存 jar 也必须覆盖响应写入与删除。
final class _SharingMemoryCookieJar implements CookieJar {
  _SharingMemoryCookieJar(this.onChanged);

  final CookieJar _inner = CookieJar();
  final void Function() onChanged;
  final _expirations = Expando<DateTime>();

  DateTime? expirationFor(Cookie cookie) =>
      _expirations[cookie] ?? cookie.expires;

  @override
  bool get ignoreExpires => _inner.ignoreExpires;

  @override
  Future<List<Cookie>> loadForRequest(Uri uri) => _inner.loadForRequest(uri);

  @override
  Future<void> saveFromResponse(Uri uri, List<Cookie> cookies) async {
    try {
      await _inner.saveFromResponse(uri, cookies);
      final now = DateTime.now();
      for (final cookie in cookies) {
        _expirations[cookie] = cookie.maxAge == null
            ? cookie.expires
            : now.add(Duration(seconds: cookie.maxAge!));
      }
    } finally {
      onChanged();
    }
  }

  @override
  Future<void> delete(Uri uri, [bool withDomainSharedCookie = false]) async {
    try {
      await _inner.delete(uri, withDomainSharedCookie);
    } finally {
      onChanged();
    }
  }

  @override
  Future<void> deleteAll() async {
    try {
      await _inner.deleteAll();
    } finally {
      onChanged();
    }
  }
}
