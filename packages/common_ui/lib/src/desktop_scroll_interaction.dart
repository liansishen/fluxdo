import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;

/// 让鼠标按下在同一次手势里停止滚动并命中指针下的控件，
/// 需与 [DesktopScrollInteractionBehavior] 配套使用。
///
/// 普通 Listener 收到事件时命中路径已被 IgnorePointer 排除；
/// 因此在框架缓存真实按下路径前停止命中的滚动容器，不合成或重放事件。
mixin DesktopScrollInteractionBinding on GestureBinding {
  @override
  void handlePointerEvent(PointerEvent event) {
    if (event is PointerDownEvent &&
        event.kind == PointerDeviceKind.mouse &&
        (event.buttons == kPrimaryMouseButton ||
            event.buttons == kSecondaryMouseButton)) {
      final visited = <_RenderScrollInteractionBoundary>{};
      while (true) {
        final probe = HitTestResult();
        hitTestInView(probe, event.position, event.viewId);
        final boundaries = probe.path
            .map((entry) => entry.target)
            .whereType<_RenderScrollInteractionBoundary>()
            .where((boundary) => visited.add(boundary))
            .toList();
        var stopped = false;
        for (final boundary in boundaries) {
          stopped = boundary.stopScrolling() || stopped;
        }
        // 外层滚动停止后可能露出原先被 IgnorePointer 遮住的嵌套轮播，
        // 在真实按下命中前继续探测。
        if (!stopped) break;
      }
    }
    super.handlePointerEvent(event);
  }
}

/// 保留滚动物理、拖动设备和装饰，以及嵌套列表和 PageView 的局部配置。
/// 触摸仍沿用 Flutter 原生的首次点击停止惯性行为。
class DesktopScrollInteractionBehavior extends ScrollBehavior {
  const DesktopScrollInteractionBehavior({
    this.delegate = const MaterialScrollBehavior(),
  });

  final ScrollBehavior delegate;

  @override
  ScrollBehavior copyWith({
    bool? scrollbars,
    bool? overscroll,
    Set<PointerDeviceKind>? dragDevices,
    MultitouchDragStrategy? multitouchDragStrategy,
    Set<LogicalKeyboardKey>? pointerAxisModifiers,
    ScrollPhysics? physics,
    TargetPlatform? platform,
    ScrollViewKeyboardDismissBehavior? keyboardDismissBehavior,
  }) => DesktopScrollInteractionBehavior(
    delegate: delegate.copyWith(
      scrollbars: scrollbars,
      overscroll: overscroll,
      dragDevices: dragDevices,
      multitouchDragStrategy: multitouchDragStrategy,
      pointerAxisModifiers: pointerAxisModifiers,
      physics: physics,
      platform: platform,
      keyboardDismissBehavior: keyboardDismissBehavior,
    ),
  );

  @override
  Widget buildScrollbar(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) {
    final decorated = delegate.buildScrollbar(context, child, details);
    // 使用 Scrollable 自身的上下文，而非可能被多个分页复用的 controller。
    final state = context is StatefulElement ? context.state : null;
    if (state is! ScrollableState) return decorated;
    return _ScrollInteractionBoundary(scrollable: state, child: decorated);
  }

  @override
  Widget buildOverscrollIndicator(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) => delegate.buildOverscrollIndicator(context, child, details);
  @override
  TargetPlatform getPlatform(BuildContext context) =>
      delegate.getPlatform(context);
  @override
  Set<PointerDeviceKind> get dragDevices => delegate.dragDevices;
  @override
  Set<LogicalKeyboardKey> get pointerAxisModifiers =>
      delegate.pointerAxisModifiers;
  @override
  MultitouchDragStrategy getMultitouchDragStrategy(BuildContext context) =>
      delegate.getMultitouchDragStrategy(context);
  @override
  GestureVelocityTrackerBuilder velocityTrackerBuilder(BuildContext context) =>
      delegate.velocityTrackerBuilder(context);
  @override
  ScrollPhysics getScrollPhysics(BuildContext context) =>
      delegate.getScrollPhysics(context);
  @override
  ScrollViewKeyboardDismissBehavior getKeyboardDismissBehavior(
    BuildContext context,
  ) => delegate.getKeyboardDismissBehavior(context);
  @override
  bool shouldNotify(covariant DesktopScrollInteractionBehavior oldDelegate) =>
      delegate.runtimeType != oldDelegate.delegate.runtimeType ||
      delegate.shouldNotify(oldDelegate.delegate);
}

class _ScrollInteractionBoundary extends SingleChildRenderObjectWidget {
  const _ScrollInteractionBoundary({
    required this.scrollable,
    required super.child,
  });
  final ScrollableState scrollable;
  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderScrollInteractionBoundary(scrollable);
  @override
  void updateRenderObject(
    BuildContext context,
    _RenderScrollInteractionBoundary renderObject,
  ) {
    renderObject.scrollable = scrollable;
  }
}

class _RenderScrollInteractionBoundary extends RenderProxyBox {
  _RenderScrollInteractionBoundary(this.scrollable);
  ScrollableState scrollable;

  bool stopScrolling() {
    if (!attached || !scrollable.mounted) return false;
    final position = scrollable.position;
    if (!position.hasPixels || !position.isScrollingNotifier.value) {
      return false;
    }
    // 沿用 Scrollable 的惯性取消路径；不伪造位置变化，保留越界回弹。
    position.pointerScroll(0);
    return true;
  }
}
