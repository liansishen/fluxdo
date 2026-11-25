import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/widgets/common/animation_visibility.dart';
import 'package:fluxdo/widgets/common/avatar_glow.dart';
import 'package:fluxdo/widgets/common/skeleton.dart';
import 'package:fluxdo_render/fluxdo_render.dart' show ScreenshotMode;
import 'package:visibility_detector/visibility_detector.dart';

class _Stream extends ImageStreamCompleter {
  int listeners = 0;

  @override
  void addListener(ImageStreamListener listener) {
    listeners++;
    super.addListener(listener);
  }

  @override
  void removeListener(ImageStreamListener listener) {
    listeners--;
    super.removeListener(listener);
  }

  void frame(ui.Image image) => setImage(ImageInfo(image: image));
}

class _Provider extends ImageProvider<_Provider> {
  _Provider(this.stream);
  final _Stream stream;

  @override
  Future<_Provider> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture<_Provider>(this);

  @override
  ImageStreamCompleter loadImage(_Provider key, ImageDecoderCallback decode) =>
      stream;
}

Future<ui.Image> _image() {
  final recorder = ui.PictureRecorder();
  Canvas(recorder).drawColor(const Color(0xff123456), BlendMode.src);
  return recorder.endRecording().toImage(1, 1);
}

class _TickerProbe extends StatefulWidget {
  const _TickerProbe({required this.onTick});
  final VoidCallback onTick;
  @override
  State<_TickerProbe> createState() => _TickerProbeState();
}

class _TickerProbeState extends State<_TickerProbe>
    with SingleTickerProviderStateMixin {
  late final AnimationController controller;
  @override
  void initState() {
    super.initState();
    controller =
        AnimationController(vsync: this, duration: const Duration(seconds: 1))
          ..addListener(widget.onTick)
          ..repeat();
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const SizedBox(width: 20, height: 20);
}

void main() {
  setUp(() {
    VisibilityDetectorController.instance.updateInterval = Duration.zero;
  });
  tearDown(() {
    VisibilityDetectorController.instance.updateInterval = const Duration(
      milliseconds: 500,
    );
  });

  testWidgets('视口、祖先 TickerMode 与窗口状态共同控制图片监听和 ticker', (tester) async {
    final stream = _Stream();
    final provider = _Provider(stream);
    var ticks = 0;
    var ancestorEnabled = true;
    var offset = 0.0;
    late StateSetter rebuild;
    await tester.pumpWidget(
      MaterialApp(
        home: AppAnimationLifecycle(
          child: StatefulBuilder(
            builder: (context, setState) {
              rebuild = setState;
              return TickerMode(
                enabled: ancestorEnabled,
                child: Stack(
                  children: [
                    Positioned(
                      top: offset,
                      child: AnimationVisibility(
                        child: SizedBox(
                          width: 40,
                          height: 40,
                          child: Stack(
                            children: [
                              Image(image: provider),
                              _TickerProbe(onTick: () => ticks++),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
    await tester.pump();
    stream.frame(await _image());
    await tester.pump(const Duration(milliseconds: 100));
    expect(stream.listeners, 1);
    expect(ticks, greaterThan(0));

    rebuild(() => offset = 2000);
    await tester.pump();
    await tester.pump();
    final stopped = ticks;
    await tester.pump(const Duration(milliseconds: 100));
    expect(stream.listeners, 0);
    expect(ticks, stopped);

    rebuild(() => offset = 0);
    await tester.pump();
    await tester.pump();
    expect(stream.listeners, 1);
    rebuild(() => ancestorEnabled = false);
    await tester.pump();
    expect(stream.listeners, 0);
    rebuild(() => ancestorEnabled = true);
    await tester.pump();
    expect(stream.listeners, 1);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    final inactiveTicks = ticks;
    await tester.pump(const Duration(milliseconds: 100));
    expect(stream.listeners, 0);
    expect(ticks, inactiveTicks);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(stream.listeners, 1);
    await tester.pump(const Duration(milliseconds: 100));
    expect(ticks, greaterThan(inactiveTicks));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    await tester.pump();
    final hiddenTicks = ticks;
    await tester.pump(const Duration(milliseconds: 100));
    expect(stream.listeners, 0);
    expect(ticks, hiddenTicks);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(stream.listeners, 1);
    await tester.pump(const Duration(milliseconds: 100));
    expect(ticks, greaterThan(hiddenTicks));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('截图模式在不可见时仍能取得图片首帧', (tester) async {
    final stream = _Stream();
    final provider = _Provider(stream);
    await tester.pumpWidget(
      MaterialApp(
        home: ScreenshotMode(
          enabled: true,
          child: Stack(
            children: [
              Positioned(
                top: 2000,
                child: AnimationVisibility(
                  child: Image(image: provider, width: 20, height: 20),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
    stream.frame(await _image());
    await tester.pump();
    expect(stream.listeners, 1);
    expect(tester.widget<RawImage>(find.byType(RawImage)).image, isNotNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('光晕和骨架滚出视口后不再预约动画帧', (tester) async {
    final scroll = ScrollController();
    addTearDown(scroll.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: SingleChildScrollView(
          controller: scroll,
          child: const Column(
            children: [
              AvatarGlow(child: SizedBox(width: 20, height: 20)),
              Skeleton(child: SkeletonBox(width: 20, height: 20)),
              SizedBox(height: 2000),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
    expect(tester.binding.transientCallbackCount, greaterThan(0));
    scroll.jumpTo(scroll.position.maxScrollExtent);
    await tester.pump();
    await tester.pump();
    expect(tester.binding.transientCallbackCount, 0);
    scroll.jumpTo(0);
    await tester.pump();
    await tester.pump();
    expect(tester.binding.transientCallbackCount, greaterThan(0));
    await tester.pumpWidget(const SizedBox());
  });
}
