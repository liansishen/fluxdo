import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:fluxdo_render/fluxdo_render.dart' show ScreenshotMode;
import 'package:visibility_detector/visibility_detector.dart';

/// 根据视口和上层 TickerMode 暂停动画，保留子树及已显示的图片帧。
class AnimationVisibility extends StatefulWidget {
  const AnimationVisibility({super.key, required this.child});

  final Widget child;

  @override
  State<AnimationVisibility> createState() => _AnimationVisibilityState();
}

class _AnimationVisibilityState extends State<AnimationVisibility> {
  bool _visible = false;
  final Key _detectorKey = UniqueKey();

  @override
  Widget build(BuildContext context) {
    final enabled =
        TickerMode.of(context) && (_visible || ScreenshotMode.of(context));
    return VisibilityDetector(
      key: _detectorKey,
      onVisibilityChanged: (info) {
        final visible = info.visibleFraction > 0;
        if (visible != _visible && mounted) {
          setState(() => _visible = visible);
        }
      },
      child: TickerMode(enabled: enabled, child: widget.child),
    );
  }
}

/// 仅在前台 resumed 时播放动画；失焦、隐藏和最小化均暂停。
class AppAnimationLifecycle extends StatefulWidget {
  const AppAnimationLifecycle({super.key, required this.child});

  final Widget child;

  static final _animationEnabled = ValueNotifier<bool>(true);

  /// 窗口隐藏时不再构建，解码器必须直接订阅此通知而非等待 TickerMode。
  static ValueListenable<bool> get animationEnabled => _animationEnabled;

  @override
  State<AppAnimationLifecycle> createState() => _AppAnimationLifecycleState();
}

class _AppAnimationLifecycleState extends State<AppAnimationLifecycle>
    with WidgetsBindingObserver {
  late bool _enabled;

  bool _shouldAnimate(AppLifecycleState? state) =>
      state == null || state == AppLifecycleState.resumed;

  @override
  void initState() {
    super.initState();
    _enabled = _shouldAnimate(WidgetsBinding.instance.lifecycleState);
    AppAnimationLifecycle._animationEnabled.value = _enabled;
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final enabled = _shouldAnimate(state);
    AppAnimationLifecycle._animationEnabled.value = enabled;
    if (enabled != _enabled) setState(() => _enabled = enabled);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => TickerMode(
    enabled: _enabled && TickerMode.of(context),
    child: widget.child,
  );
}
