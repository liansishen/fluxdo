import 'package:common_ui/common_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/preferences_provider.dart';
import '../../theme/mojian_theme.dart';

/// 只订阅玻璃偏好，避免调整档位时重建 MainApp 的其他主题/窗口逻辑。
/// 墨笺统一使用纸色实底与细线；经典和 Claude 仍遵循玻璃开关与档位。
class AppGlassSettings extends ConsumerWidget {
  const AppGlassSettings({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mojian = Theme.of(context).extension<MojianTokens>();
    final settings = ref.watch(
      preferencesProvider.select(
        (p) =>
            GlassSettings(enabled: p.glassEnabled, level: p.glassEffectLevel),
      ),
    );
    return GlassSettingsScope(
      settings: mojian == null
          ? settings
          : GlassSettings(
              enabled: settings.enabled,
              level: settings.level,
              solid: GlassSolidStyle(
                fill: mojian.paper,
                border: mojian.ruleStrong,
              ),
            ),
      child: child,
    );
  }
}
