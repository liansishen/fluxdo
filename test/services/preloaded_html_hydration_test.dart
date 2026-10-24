import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/preloaded_data_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

String _snapshot(Map<String, dynamic> data, {bool hasSetup = true}) =>
    '${hasSetup ? '<meta id="data-discourse-setup">' : ''}'
    '<script id="data-preloaded" type="application/json">'
    '${jsonEncode(data)}</script>';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late PreloadedDataService preload;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    preload = PreloadedDataService()..reset();
  });
  tearDown(() => preload.reset());

  test('启动复用完整访客首页，不残留此前快照的登录用户', () async {
    await preload.hydrateFromHtml(_snapshot({
      'currentUser': {'id': 1, 'username': 'previous'},
      'siteSettings': {'title': '旧快照'},
      'site': {'categories': []},
    }));
    final hydrated = await preload.hydrateFromHtml(
      _snapshot({
        'siteSettings': {'title': '访客首页'},
        'site': {'categories': [{'id': 42, 'name': '公开分类'}]},
      }),
      allowAnonymous: true,
    );

    expect(hydrated, isTrue);
    expect(preload.isLoaded, isTrue);
    expect(preload.currentUserSync, isNull);
    expect(preload.siteSettingsSync?['title'], '访客首页');
    expect(preload.categoryIdsSync, {42});
  });

  test('登录收口不能把匿名首页视为已登录快照', () async {
    final hydrated = await preload.hydrateFromHtml(_snapshot({
      'siteSettings': {'title': '访客首页'},
      'site': {'categories': []},
    }));

    expect(hydrated, isFalse);
    expect(preload.isLoaded, isFalse);
    expect(preload.siteSettingsSync, isNull);
    expect(preload.currentUserSync, isNull);
  });

  test('允许访客也不接受缺失站点引导数据或挑战页面', () async {
    final incomplete = [
      _snapshot({'siteSettings': {}}),
      _snapshot({'site': {}}),
      _snapshot({'siteSettings': {}, 'site': {}}, hasSetup: false),
      '<html><title>Just a moment...</title></html>',
    ];
    for (final html in incomplete) {
      expect(
        await preload.hydrateFromHtml(html, allowAnonymous: true),
        isFalse,
      );
      expect(preload.isLoaded, isFalse);
      expect(preload.siteSync, isNull);
    }
  });
}
