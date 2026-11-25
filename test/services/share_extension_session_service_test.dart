import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:enhanced_cookie_jar/enhanced_cookie_jar.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/constants.dart';
import 'package:fluxdo/services/share_extension_session_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('fluxdo/share_extension');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUpAll(() async {
    await AppConstants.initUserAgent();
  });
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('共享凭据仅包含当前主域根路径的必要 Cookie', () async {
    final directory = await Directory.systemTemp.createTemp('share-session-');
    addTearDown(() => directory.delete(recursive: true));
    final service = ShareExtensionSessionService(host: 'linux.do');
    final jar = service.persistentJar(FileCookieStore(directory.path));
    await jar.saveFromResponse(Uri.parse('https://linux.do/'), [
      Cookie('_t', 'current-session')..path = '/',
      Cookie('cf_clearance', 'challenge-token')..path = '/',
      Cookie('unrelated-secret', 'must-not-share')..path = '/',
      Cookie('_forum_session', 'expired')
        ..path = '/'
        ..expires = DateTime.utc(2000),
    ]);
    await jar.saveFromResponse(Uri.parse('https://idcflare.com/'), [
      Cookie('_t', 'other-site'),
    ]);
    await jar.saveFromResponse(Uri.parse('https://connect.linux.do/'), [
      Cookie('_t', 'oauth-domain'),
    ]);
    await jar.saveFromResponse(Uri.parse('https://linux.do/private/'), [
      Cookie('_t', 'private-path')..path = '/private',
    ]);
    final snapshot = Completer<Map<Object?, Object?>>();
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (!snapshot.isCompleted) {
        snapshot.complete(Map<Object?, Object?>.from(call.arguments as Map));
      }
      return null;
    });
    service.start(jar);
    final value = await snapshot.future.timeout(const Duration(seconds: 5));
    expect(value['host'], 'linux.do');
    expect(
      value['cookieHeader'],
      '_t=current-session; cf_clearance=challenge-token',
    );
  });

  test('退出等待正在写入的快照后清空，清理过程不会重新发布旧登录态', () async {
    final service = ShareExtensionSessionService(host: 'linux.do');
    final jar = service.memoryJar();
    await jar.saveFromResponse(Uri.parse('https://linux.do/'), [
      Cookie('_t', 'old-session'),
    ]);
    final writing = Completer<void>();
    final release = Completer<void>();
    var persistedHeader = '';
    messenger.setMockMethodCallHandler(channel, (call) async {
      final header = (call.arguments as Map)['cookieHeader'] as String;
      if (header == '_t=old-session') {
        writing.complete();
        await release.future;
      }
      persistedHeader = header;
      return null;
    });
    service.start(jar);
    await writing.future.timeout(const Duration(seconds: 5));
    final clearing = service.beginLogout();
    await jar.saveFromResponse(Uri.parse('https://linux.do/'), [
      Cookie('_t', 'late-webview-session'),
    ]);
    await jar.deleteAll();
    release.complete();
    await clearing.timeout(const Duration(seconds: 5));
    service.endLogout();
    expect(persistedHeader, isEmpty);
  });
}
