import 'package:common_ui/common_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/l10n/s.dart';
import 'package:fluxdo/providers/theme_provider.dart';
import 'package:fluxdo/settings/definitions/appearance_defs.dart';
import 'package:fluxdo/settings/definitions/bottom_nav_defs.dart';
import 'package:fluxdo/settings/settings_renderer.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  Future<SharedPreferences> pumpSettings(
    WidgetTester tester, {
    bool bottomNav = false,
  }) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
        child: TranslationProvider(
          child: MaterialApp(
            locale: const Locale('zh'),
            supportedLocales: AppLocaleUtils.supportedLocales,
            localizationsDelegates: const [
              GlobalMaterialLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
            ],
            home: Scaffold(
              body: Builder(
                builder: (context) {
                  final group = bottomNav
                      ? buildBottomNavGroups(context).first
                      : buildAppearanceGroups(context).firstWhere(
                          (group) => group.title == context.l10n.appearance_glass,
                        );
                  return ListView(
                    children: [
                      for (final item in group.items)
                        SettingsRenderer(model: item),
                    ],
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return prefs;
  }

  testWidgets('外观玻璃档位可选，关闭总开关后禁用但保留选择', (tester) async {
    final prefs = await pumpSettings(tester);
    final choices = find.byType(RadioListTile<GlassEffectLevel>);
    final radioGroup = find.byType(RadioGroup<GlassEffectLevel>);
    expect(choices, findsNWidgets(3));
    expect(
      tester.widget<RadioGroup<GlassEffectLevel>>(radioGroup).groupValue,
      GlassEffectLevel.auto,
    );

    await tester.tap(find.text('基础磨砂'));
    await tester.pumpAndSettle();
    expect(prefs.getString('pref_glass_effect_level'), 'basic');

    await tester.tap(find.byType(SwitchListTile));
    await tester.pumpAndSettle();
    expect(prefs.getBool('pref_glass_enabled'), isFalse);
    expect(
      tester.widgetList<RadioListTile<GlassEffectLevel>>(choices).every(
        (tile) => tile.enabled != true,
      ),
      isTrue,
    );
    await tester.tap(find.text('完整玻璃'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<RadioGroup<GlassEffectLevel>>(radioGroup).groupValue,
      GlassEffectLevel.basic,
      reason: '禁用时不能修改档位，原选择仍然可见',
    );
    expect(prefs.getString('pref_glass_effect_level'), 'basic');

    await tester.tap(find.byType(SwitchListTile));
    await tester.pumpAndSettle();
    expect(
      tester.widgetList<RadioListTile<GlassEffectLevel>>(choices).every(
        (tile) => tile.enabled == true,
      ),
      isTrue,
    );
    expect(
      tester.widget<RadioGroup<GlassEffectLevel>>(radioGroup).groupValue,
      GlassEffectLevel.basic,
    );
    await tester.tap(find.text('完整玻璃'));
    await tester.pumpAndSettle();
    expect(prefs.getString('pref_glass_effect_level'), 'full');
    expect(tester.takeException(), isNull);
  });

  testWidgets('底栏外观只保留布局开关，并说明玻璃效果统一在外观设置调整', (tester) async {
    await pumpSettings(tester, bottomNav: true);
    expect(find.byType(SwitchListTile), findsNWidgets(2));
    expect(find.text('玻璃效果'), findsOneWidget);
    expect(
      find.text('前往外观设置，统一调整底栏与编辑工具岛的玻璃效果。'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });
}
