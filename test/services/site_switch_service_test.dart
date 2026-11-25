import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/config/forum_site.dart';
import 'package:fluxdo/services/log/log_writer.dart';
import 'package:fluxdo/services/site_context.dart';
import 'package:fluxdo/services/site_data_lifecycle.dart';
import 'package:fluxdo/services/site_switch_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('fluxdo/site_switch');
  late SharedPreferences preferences;
  late Directory logDirectory;

  setUp(() async {
    SharedPreferences.setMockInitialValues({
      SiteContext.selectionKey: ForumSite.linuxDo.id,
      'current_user_cache': '原站用户缓存',
      'site:idcflare:current_user_cache': '新站用户缓存',
      'theme_mode': 'light',
    });
    preferences = await SharedPreferences.getInstance();
    logDirectory = await Directory.systemTemp.createTemp('site-switch-logs-');
    await LogWriter.initForTesting(logDirectory);
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    await LogWriter.resetForTesting();
    await logDirectory.delete(recursive: true);
  });

  test('缺少原生通道时保留原站并将失败阶段写入日志', () async {
    await preferences.setString(
      SiteSwitchService.pendingUrlKey,
      'https://linux.do/t/old/42',
    );
    await expectLater(
      SiteSwitchService.instance.switchTo(ForumSite.idcFlare),
      throwsA(isA<MissingPluginException>()),
    );
    expect(preferences.getString(SiteContext.selectionKey), 'linuxdo');
    expect(preferences.getString(SiteSwitchService.pendingUrlKey),
        'https://linux.do/t/old/42');
    expect(SiteSwitchService.instance.isSwitching.value, isFalse);
    await LogWriter.instance.flushNow();
    final entries = (await LogWriter.readAllContent())
        .split('\n')
        .where((line) => line.isNotEmpty)
        .map((line) => jsonDecode(line) as Map<String, dynamic>);
    final failure = entries.singleWhere((entry) => entry['level'] == 'error');
    expect(failure['tag'], 'SiteSwitch');
    expect(failure['stage'], 'check_support');
    expect(failure['errorType'], 'MissingPluginException');
    expect(failure['fromSite'], 'linuxdo');
    expect(failure['toSite'], 'idcflare');
  });

  test('草稿保存失败时留在原站，不覆盖选择和其他站数据', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async => true);
    final unregister = SiteDataLifecycle.register(() async {
      throw const FileSystemException('草稿写入失败');
    });
    try {
      await expectLater(
        SiteSwitchService.instance.switchTo(ForumSite.idcFlare),
        throwsA(isA<FileSystemException>()),
      );
      expect(preferences.getString(SiteContext.selectionKey), 'linuxdo');
      expect(SiteSwitchService.instance.isSwitching.value, isFalse);
      expect(preferences.getString('current_user_cache'), '原站用户缓存');
      expect(preferences.getString('site:idcflare:current_user_cache'), '新站用户缓存');
    } finally {
      unregister();
    }
  });

  test('平台重启失败时回滚选择和待打开链接，允许再次切换', () async {
    await preferences.setString(
      SiteSwitchService.pendingUrlKey,
      'https://linux.do/t/old/42',
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'isSupported') return true;
      throw PlatformException(
        code: 'RESTART_FAILED',
        message: 'https://idcflare.com/auth?key=敏感凭据',
        details: {'token': '敏感凭据'},
      );
    });
    await expectLater(
      SiteSwitchService.instance.switchTo(
        ForumSite.idcFlare,
        openUrl: Uri.parse('https://idcflare.com/t/new/42'),
      ),
      throwsA(isA<PlatformException>()),
    );
    expect(preferences.getString(SiteContext.selectionKey), 'linuxdo');
    expect(preferences.getString(SiteSwitchService.pendingUrlKey),
        'https://linux.do/t/old/42');
    expect(SiteSwitchService.instance.isSwitching.value, isFalse);
    expect(preferences.getString('current_user_cache'), '原站用户缓存');
    expect(preferences.getString('site:idcflare:current_user_cache'), '新站用户缓存');
    await LogWriter.instance.flushNow();
    final content = await LogWriter.readAllContent();
    final failure = content
        .split('\n')
        .where((line) => line.isNotEmpty)
        .map((line) => jsonDecode(line) as Map<String, dynamic>)
        .singleWhere((entry) => entry['level'] == 'error');
    expect(failure['stage'], 'restart');
    expect(failure['errorCode'], 'RESTART_FAILED');
    expect(failure['errorType'], 'PlatformException');
    expect(content, isNot(contains('敏感凭据')));
    expect(content, isNot(contains('/auth?key=')));
  });

  test('拒绝不属于目标站点的链接，不让同话题 ID 越站打开', () async {
    await expectLater(
      SiteSwitchService.instance.switchTo(
        ForumSite.idcFlare,
        openUrl: Uri.parse('https://idcflare.com.evil.example/t/42'),
      ),
      throwsArgumentError,
    );
    expect(preferences.getString(SiteContext.selectionKey), 'linuxdo');
    expect(SiteSwitchService.instance.isSwitching.value, isFalse);
  });

  test('成功切站仅保存新选择，旧运行环境与两站数据保持原归属', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async => true);
    await SiteSwitchService.instance.switchTo(ForumSite.idcFlare);
    expect(preferences.getString(SiteContext.selectionKey), 'idcflare');
    expect(SiteContext.current, ForumSite.linuxDo);
    expect(preferences.getString('current_user_cache'), '原站用户缓存');
    expect(preferences.getString('site:idcflare:current_user_cache'), '新站用户缓存');
    expect(preferences.getString('theme_mode'), 'light');
  });
}
