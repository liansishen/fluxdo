import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/image_stream_lifecycle.dart';

void main() {
  // 自动测试绑定会重写暖帧并跳过事件锁；这里使用框架的真实调度路径。
  final binding = LiveTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  for (final background in [
    AppLifecycleState.hidden,
    AppLifecycleState.paused,
  ]) {
    testWidgets('$background 回收后，帧未完成时也不阻塞回前台点击', (tester) async {
      var taps = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => taps++,
                child: const Text('可点击按钮'),
              ),
            ),
          ),
        ),
      );
      binding.handleAppLifecycleStateChanged(background);
      try {
        ManagedImageCache.scheduleDisposalFrame();
        // 只执行调度微任务，保留“维护帧尚未完成”的真实窗口。
        await Future<void>.value();
        expect(binding.locked, isFalse);
        binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
        await tester.tap(find.text('可点击按钮'));
        await tester.pump();
        expect(taps, 1);
        await tester.tap(find.text('可点击按钮'));
        await tester.pump();
        expect(taps, 2);
      } finally {
        binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
        await tester.pumpWidget(const SizedBox());
      }
    });
  }
}
