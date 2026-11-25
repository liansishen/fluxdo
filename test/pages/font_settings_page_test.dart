import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fluxdo/l10n/s.dart';
import 'package:fluxdo/pages/font_settings_page.dart';
import 'package:fluxdo/providers/theme_provider.dart';
import 'package:fluxdo/services/custom_font_service.dart';
import 'package:fluxdo/services/recommended_font_service.dart';
import 'package:fluxdo/theme/mojian_theme.dart';

/// 临时目录用同步 IO 准备（testWidgets 的 fake async 里真实异步 IO 不推进）。
late Directory _tempDir;
late File _importedFile;
late File _downloadedFile;

String _manifest() => jsonEncode({
  'version': 1,
  'fonts': [
    {
      'id': 'downloaded-font',
      'name': '已下字体',
      'nameEn': 'Downloaded Font',
      'file': 'Downloaded.ttf',
      'size': _downloadedFile.lengthSync(),
      'urls': ['https://example.com/a.ttf'],
    },
    {
      'id': 'remote-font',
      'name': '远端字体',
      'nameEn': 'Remote Font',
      'file': 'Remote.ttf',
      'size': 1048576,
      'domesticMirror': true,
      'urls': ['https://example.com/b.ttf'],
    },
  ],
});

Future<({SharedPreferences prefs, ProviderContainer container})> _pump(
  WidgetTester tester, {
  Map<String, Object> prefsSeed = const {},
}) async {
  SharedPreferences.setMockInitialValues(prefsSeed);
  final prefs = await SharedPreferences.getInstance();
  final service = RecommendedFontService(
    directoryProvider: () async =>
        Directory('${_tempDir.path}/recommended_fonts'),
    builtinManifestLoader: () async => _manifest(),
    remoteManifestLoader: () async => null,
  );
  await tester.runAsync(service.ensureLoaded);
  // 在真实异步区准备引擎字体，避免页面预览读盘滞留在假时钟里。
  await tester.runAsync(() async {
    await CustomFontService.load(_downloadedFile.path);
    if (_importedFile.existsSync()) {
      await CustomFontService.load(_importedFile.path);
    }
  });
  final container = ProviderContainer(
    overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
  );
  addTearDown(container.dispose);
  tester.view.physicalSize = const Size(420, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: TranslationProvider(
        child: Consumer(
          builder: (context, ref, _) {
            final state = ref.watch(themeProvider);
            return MaterialApp(
              locale: const Locale('zh'),
              localizationsDelegates: const [
                GlobalMaterialLocalizations.delegate,
                GlobalWidgetsLocalizations.delegate,
                GlobalCupertinoLocalizations.delegate,
              ],
              supportedLocales: AppLocaleUtils.supportedLocales,
              theme: MojianTheme.build(
                scheme: MojianTheme.colorScheme(
                  Brightness.light,
                  MojianAccent.cinnabar,
                ),
                accent: MojianAccent.cinnabar,
                fontFamily: state.fontFamilyName,
                titleFontFamily: state.titleFontFamilyName,
                pageTransitionsTheme: const PageTransitionsTheme(),
                iconTheme: const IconThemeData(),
                primaryIconTheme: const IconThemeData(),
              ),
              home: FontSettingsPage(recommendedFontService: service),
            );
          },
        ),
      ),
    ),
  );
  await tester.pump();
  return (prefs: prefs, container: container);
}

Finder _row(String title) =>
    find.ancestor(of: find.text(title), matching: find.byType(ListTile));

Finder _inRow(String title, Finder finder) =>
    find.descendant(of: _row(title), matching: finder);

void main() {
  setUpAll(() {
    _tempDir = Directory.systemTemp.createTempSync('fluxdo_font_page');
    Directory('${_tempDir.path}/recommended_fonts').createSync();
    Directory('${_tempDir.path}/custom_fonts').createSync();
    final realFont = File('assets/fonts/MojianSerif-Regular.otf');
    _downloadedFile = realFont.copySync(
      '${_tempDir.path}/recommended_fonts/downloaded-font.ttf',
    );
    _importedFile = realFont.copySync(
      '${_tempDir.path}/custom_fonts/custom_font_1.otf',
    );
  });

  tearDownAll(() {
    if (_tempDir.existsSync()) _tempDir.deleteSync(recursive: true);
  });

  testWidgets('点已下载的推荐字体直接启用', (tester) async {
    final env = await _pump(tester);

    await tester.runAsync(() async {
      await tester.tap(_row('已下字体'));
      // 注册字体要真实读文件
      for (
        var i = 0;
        i < 50 &&
            env.container.read(themeProvider).fontFamily !=
                AppFontFamily.custom;
        i++
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    });
    await tester.pump();

    final state = env.container.read(themeProvider);
    expect(state.fontFamily, AppFontFamily.custom);
    expect(state.customFontPath, _downloadedFile.path);
    expect(find.text('当前：已下字体'), findsOneWidget);
    // 自己选的字体：标题默认跟着换
    expect(
      tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
      isFalse,
    );
  });

  testWidgets('导入过的字体单独一行：换走后还在，可删掉', (tester) async {
    final env = await _pump(
      tester,
      prefsSeed: {
        'font_family': 'miSans',
        'imported_font_path': _importedFile.path,
        'imported_font_name': 'Mine.otf',
      },
    );

    expect(_row('Mine.otf'), findsOneWidget);
    expect(_inRow('Mine.otf', find.text('导入的字体')), findsOneWidget);

    await tester.runAsync(() async {
      await tester.tap(_row('Mine.otf'));
      for (
        var i = 0;
        i < 50 &&
            env.container.read(themeProvider).fontFamily !=
                AppFontFamily.custom;
        i++
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    });
    await tester.pump();
    expect(
      env.container.read(themeProvider).customFontPath,
      _importedFile.path,
    );

    // 换回系统默认，导入的那行还在，且能删
    await tester.tap(_row('系统默认'));
    await tester.pump();
    expect(_row('Mine.otf'), findsOneWidget);
    await tester.runAsync(() async {
      await tester.tap(_inRow('Mine.otf', find.byTooltip('删除')));
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pump();
    expect(_row('Mine.otf'), findsNothing);
    expect(env.container.read(themeProvider).importedFontPath, isNull);
    expect(env.prefs.getString('imported_font_path'), isNull);
    expect(_importedFile.existsSync(), isFalse);
    expect(env.container.read(themeProvider).fontFamily, AppFontFamily.system);
    // 恢复给后面的用例
    File('assets/fonts/MojianSerif-Regular.otf').copySync(_importedFile.path);
  });

  testWidgets('关掉宋体标题：系统默认下标题也用正文字体', (tester) async {
    final env = await _pump(tester);

    await tester.tap(find.byType(SwitchListTile));
    await tester.pump();
    // 主题切换有过渡动画
    await tester.pump(const Duration(milliseconds: 400));

    final state = env.container.read(themeProvider);
    expect(state.mojianSerifTitles, isFalse);
    expect(state.titleFontFamilyName, MojianTheme.platformBodyFamily);
    final title = tester.widget<Text>(find.text('标题这样显示'));
    final style = DefaultTextStyle.of(tester.element(find.text('标题这样显示'))).style
        .merge(title.style);
    expect(style.fontFamily, isNot(MojianTokens.serifFamily));
  });

  testWidgets('导入的字体文件丢了：标红提示，且能删掉', (tester) async {
    await _pump(
      tester,
      prefsSeed: {
        'font_family': 'custom',
        CustomFontService.pathPrefKey: '${_tempDir.path}/custom_fonts/gone.ttf',
        CustomFontService.namePrefKey: 'Gone.ttf',
      },
    );

    expect(find.text('当前：字体文件已丢失'), findsOneWidget);
    expect(_inRow('Gone.ttf', find.text('字体文件已丢失')), findsOneWidget);
    expect(_inRow('Gone.ttf', find.byTooltip('删除')), findsOneWidget);
  });
}
