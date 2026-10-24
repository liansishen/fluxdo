import 'package:common_ui/common_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/l10n/s.dart';
import 'package:fluxdo/providers/theme_provider.dart';
import 'package:fluxdo/theme/claude_theme.dart';
import 'package:fluxdo/theme/mojian_theme.dart';
import 'package:fluxdo/settings/definitions/appearance_defs.dart';
import 'package:fluxdo/settings/definitions/bottom_nav_defs.dart';
import 'package:fluxdo/settings/settings_renderer.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  Future<SharedPreferences> pumpSettings(
    WidgetTester tester, {
    bool bottomNav = false,
    UiStyle style = UiStyle.classic,
  }) async {
    SharedPreferences.setMockInitialValues({'ui_style': style.name});
    final prefs = await SharedPreferences.getInstance();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
        child: TranslationProvider(
          child: MaterialApp(
            theme: ThemeData(
              extensions: [
                if (style == UiStyle.mojian)
                  MojianTokens.of(Brightness.light, MojianAccent.cinnabar),
                if (style == UiStyle.claude) ClaudeTokens.of(Brightness.light),
              ],
            ),
            locale: const Locale('zh'),
            supportedLocales: AppLocaleUtils.supportedLocales,
            localizationsDelegates: const [
              GlobalMaterialLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
            ],
            home: Scaffold(
              body: Consumer(
                builder: (context, ref, _) {
                  final group = bottomNav
                      ? buildBottomNavGroups(context).first
                      : buildAppearanceGroups(context).firstWhere(
                          (group) =>
                              group.title == context.l10n.appearance_glass,
                        );
                  return ListView(
                    children: [
                      if (group.isVisible(ref))
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
      tester
          .widgetList<RadioListTile<GlassEffectLevel>>(choices)
          .every((tile) => tile.enabled != true),
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
      tester
          .widgetList<RadioListTile<GlassEffectLevel>>(choices)
          .every((tile) => tile.enabled == true),
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

  testWidgets('玻璃分组和底栏入口只在墨笺隐藏，Claude 仍可调整', (tester) async {
    for (final style in UiStyle.values) {
      for (final bottomNav in [false, true]) {
        await pumpSettings(tester, style: style, bottomNav: bottomNav);
        expect(
          find.text(bottomNav ? '玻璃效果' : '启用玻璃效果'),
          style == UiStyle.mojian ? findsNothing : findsOneWidget,
        );
        await tester.pumpWidget(const SizedBox.shrink());
      }
    }
  });
}
