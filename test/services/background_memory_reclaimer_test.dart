import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/background_memory_reclaimer.dart';
import 'package:fluxdo/services/image_stream_lifecycle.dart';

class _TrackedStream extends ImageStreamCompleter {
  bool disposed = false;

  void emit(ui.Image image) => setImage(ImageInfo(image: image));

  @override
  void onDisposed() {
    disposed = true;
    super.onDisposed();
  }
}

_TrackedStream _cacheImage(ImageCache cache, String key, int edge) {
  final recorder = ui.PictureRecorder();
  Canvas(recorder).drawColor(Colors.blue, BlendMode.src);
  final picture = recorder.endRecording();
  final image = picture.toImageSync(edge, edge);
  picture.dispose();
  final stream = _TrackedStream();
  cache.putIfAbsent(key, () => stream);
  stream.emit(image);
  return stream;
}

void main() {
  testWidgets('短暂切出再恢复不会清理可复用图片或延迟误清理', (tester) async {
    final cache = ManagedImageCache()..maximumSizeBytes = 64 << 20;
    final policy = BackgroundMemoryReclaimer(imageCache: cache);
    final image = _cacheImage(cache, '已有图片', 3072);
    await tester.pump();
    try {
      policy.handleLifecycleState(AppLifecycleState.inactive);
      await tester.pump(const Duration(seconds: 14));
      policy.handleLifecycleState(AppLifecycleState.resumed);
      await tester.pump(const Duration(seconds: 20));
      expect(cache.statusForKey('已有图片').keepAlive, isTrue);
      expect(image.disposed, isFalse);
      expect(cache.maximumSizeBytes, 64 << 20);
    } finally {
      policy.dispose();
      cache.clear();
      cache.clearLiveImages();
      await tester.pump();
    }
  });

  testWidgets('持续后台释放未使用图片，保留活跃图片并恢复前台预算', (tester) async {
    final cache = ManagedImageCache()..maximumSizeBytes = 64 << 20;
    final policy = BackgroundMemoryReclaimer(imageCache: cache);
    final unused = _cacheImage(cache, '离开页面的图片', 3072);
    final active = _cacheImage(cache, '仍在界面上的图片', 1);
    var deliveries = 0;
    final listener = ImageStreamListener((info, _) {
      deliveries++;
      info.dispose();
    });
    active.addListener(listener);
    await tester.pump();
    try {
      policy.handleLifecycleState(AppLifecycleState.inactive);
      await tester.pump(const Duration(seconds: 10));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      policy.handleLifecycleState(AppLifecycleState.hidden);
      await tester.pump(const Duration(seconds: 5));
      await tester.pump();
      expect(unused.disposed, isTrue);
      expect(cache.statusForKey('离开页面的图片').keepAlive, isFalse);
      expect(active.disposed, isFalse);
      expect(
        cache.maximumSizeBytes,
        BackgroundMemoryReclaimer.backgroundImageCacheBytes,
      );
      expect(deliveries, 1);

      // 后台继续加载的图片也不能把可复用缓存再次撑到前台上限。
      final lateImage = _cacheImage(cache, '后台迟到图片', 3072);
      await tester.pump();
      // 第一轮处理释放通知，下一轮执行它预约的维护帧。
      await tester.pump();
      expect(lateImage.disposed, isTrue);
      expect(
        cache.currentSizeBytes,
        lessThanOrEqualTo(BackgroundMemoryReclaimer.backgroundImageCacheBytes),
      );
      policy.handleLifecycleState(AppLifecycleState.resumed);
      expect(cache.maximumSizeBytes, 64 << 20);
      active.removeListener(listener);
      active.addListener(listener);
      expect(deliveries, 2);
    } finally {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      active.removeListener(listener);
      policy.dispose();
      cache.clear();
      cache.clearLiveImages();
      await tester.pump();
    }
  });

  testWidgets('移动端挂起前立即释放旧图片，不等待后台宽限期', (tester) async {
    final cache = ManagedImageCache()..maximumSizeBytes = 64 << 20;
    final policy = BackgroundMemoryReclaimer(imageCache: cache);
    final image = _cacheImage(cache, '离开页面的图片', 3072);
    await tester.pump();
    try {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      policy.handleLifecycleState(AppLifecycleState.paused);
      await tester.pump();
      expect(image.disposed, isTrue);
      expect(cache.statusForKey('离开页面的图片').keepAlive, isFalse);
      policy.handleLifecycleState(AppLifecycleState.resumed);
      expect(cache.maximumSizeBytes, 64 << 20);
    } finally {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      policy.dispose();
      cache.clear();
      cache.clearLiveImages();
      await tester.pump();
    }
  });
}
