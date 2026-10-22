import 'package:common_ui/common_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/providers/preferences_provider.dart';
import 'package:fluxdo/providers/theme_provider.dart';
import 'package:fluxdo/widgets/common/app_glass_settings.dart';
import 'package:fluxdo/widgets/layout/adaptive_navigation.dart';
import 'package:fluxdo/widgets/markdown_editor/composer_island.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  Future<ProviderContainer> pumpSurfaces(
    WidgetTester tester, {
    bool highContrast = false,
    GlassEffectLevel level = GlassEffectLevel.basic,
    ValueChanged<int>? onDestinationSelected,
    VoidCallback? onEditorPressed,
  }) async {
    SharedPreferences.setMockInitialValues({
      'pref_bottom_nav_floating': true,
      'pref_bottom_nav_labelless': true,
      // 废弃的局部开关不能覆盖新的全局默认值。
      'pref_bottom_nav_floating_blur': false,
      'pref_glass_effect_level': level.name,
      'pref_dialog_blur': false,
    });
    final prefs = await SharedPreferences.getInstance();
    final container = ProviderContainer(
      overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(highContrast: highContrast),
            child: AppGlassSettings(child: child!),
          ),
          home: Scaffold(
            extendBody: true,
            body: Center(
              child: SizedBox(
                width: 300,
                child: ComposerIsland(
                  child: SizedBox(
                    height: 132,
                    child: Center(
                      child: TextButton(
                        onPressed: onEditorPressed ?? () {},
                        child: const Text('编辑工具'),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            bottomNavigationBar: AdaptiveBottomNavigation(
              selectedIndex: 0,
              onDestinationSelected: onDestinationSelected ?? (_) {},
              destinations: const [
                AdaptiveDestination(
                  id: 'home',
                  icon: Icon(Icons.home_outlined),
                  selectedIcon: Icon(Icons.home),
                  label: '首页',
                ),
                AdaptiveDestination(
                  id: 'profile',
                  icon: Icon(Icons.person_outline),
                  selectedIcon: Icon(Icons.person),
                  label: '我的',
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return container;
  }

  List<Size> surfaceSizes(WidgetTester tester) => tester
      .renderObjectList(find.byType(GlassSurface))
      .map((box) => (box as RenderBox).size)
      .toList();

  testWidgets('全局开关同时控制底栏和编辑工具岛，保留尺寸与操作', (tester) async {
    var editorPresses = 0;
    int? selectedDestination;
    final container = await pumpSurfaces(
      tester,
      onEditorPressed: () => editorPresses++,
      onDestinationSelected: (index) => selectedDestination = index,
    );
    expect(find.byType(GlassSurface), findsNWidgets(2));
    expect(
      find.byType(BackdropFilter),
      findsNWidgets(2),
      reason: '基础档在两处均显示磨砂，废弃的底栏关闭值不再生效',
    );
    final before = surfaceSizes(tester);
    final notifier = container.read(preferencesProvider.notifier);
    await notifier.setGlassEnabled(false);
    await tester.pumpAndSettle();
    expect(find.byType(BackdropFilter), findsNothing);
    expect(surfaceSizes(tester), before);

    await tester.tap(find.text('编辑工具'));
    await tester.tap(find.byTooltip('我的'));
    await tester.pumpAndSettle();
    expect(editorPresses, 1);
    expect(selectedDestination, 1);

    await notifier.setGlassEnabled(true);
    await tester.pumpAndSettle();
    expect(find.byType(BackdropFilter), findsNWidgets(2));
    expect(surfaceSizes(tester), before);
    expect(
      container.read(preferencesProvider).glassEffectLevel,
      GlassEffectLevel.basic,
      reason: '关闭再开启应恢复原档位',
    );
    expect(
      container.read(preferencesProvider).dialogBlur,
      isFalse,
      reason: '全局玻璃设置不控制弹窗背景模糊',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('高对比度优先使用实色，不修改用户选择的完整玻璃档位', (tester) async {
    final container = await pumpSurfaces(
      tester,
      highContrast: true,
      level: GlassEffectLevel.full,
    );
    expect(find.byType(GlassSurface), findsNWidgets(2));
    expect(find.byType(BackdropFilter), findsNothing);
    expect(find.text('编辑工具'), findsOneWidget);
    expect(find.byTooltip('首页'), findsOneWidget);
    expect(find.byTooltip('我的'), findsOneWidget);
    expect(container.read(preferencesProvider).glassEnabled, isTrue);
    expect(
      container.read(preferencesProvider).glassEffectLevel,
      GlassEffectLevel.full,
    );
    expect(tester.takeException(), isNull);
  });
}
