import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:native_animated_image/native_animated_image.dart';

// 两帧 1×1 GIF，帧数据独立，适用于真实解码路径。
final _gif = Uint8List.fromList([
  71,
  73,
  70,
  56,
  57,
  97,
  1,
  0,
  1,
  0,
  128,
  0,
  0,
  0,
  0,
  0,
  255,
  255,
  255,
  33,
  249,
  4,
  0,
  10,
  0,
  0,
  0,
  44,
  0,
  0,
  0,
  0,
  1,
  0,
  1,
  0,
  0,
  2,
  2,
  68,
  1,
  0,
  33,
  249,
  4,
  0,
  10,
  0,
  0,
  0,
  44,
  0,
  0,
  0,
  0,
  1,
  0,
  1,
  0,
  0,
  2,
  2,
  76,
  1,
  0,
  59,
]);

final _largeGif = base64Decode(
  'R0lGODlhCAAEAIEAAP8AAAAAAAAAAAAAACH/C05FVFNDQVBFMi4wAwEAAAAh+QQACgAAACwAAAAACAAEAAAIDAABCBxIsKDBgwQDAgAh+QQBCgABACwAAAAACAAEAIEAAP8AAAAAAAAAAAAIDAABCBxIsKDBgwQDAgA7',
);
Future<void> _waitForReleasedFrames() async {
  await Future.doWhile(() async {
    await Future<void>.delayed(const Duration(milliseconds: 1));
    return NativeAnimatedImageProvider.debugActiveSequences != 0;
  }).timeout(const Duration(seconds: 10));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
    NativeAnimatedImageProvider.animationEnabled = null;
    NativeAnimatedImageProvider.debugSetBudgetLimit(null);
  });

  // 原生 isolate 和引擎回调必须运行在真实时钟中，不能只把等待包进 runAsync。
  test('多动图共享预算，超额仍播放', () async {
    NativeAnimatedImageProvider.debugSetBudgetLimit(16);
    final providers = [
      NativeAnimatedImageProvider.memory(_gif, tag: '预算一'),
      NativeAnimatedImageProvider.memory(_gif, tag: '预算二'),
    ];
    final streams = <ImageStream>[];
    final listeners = <ImageStreamListener>[];
    try {
      for (final provider in providers) {
        final stream = provider.resolve(ImageConfiguration.empty);
        final ready = Completer<void>();
        final listener = ImageStreamListener(
          (info, _) {
            info.dispose();
            if (!ready.isCompleted) ready.complete();
          },
          onError: (Object error, StackTrace? stack) {
            if (!ready.isCompleted) ready.completeError(error, stack);
          },
        );
        streams.add(stream);
        listeners.add(listener);
        stream.addListener(listener);
        await ready.future.timeout(const Duration(seconds: 10));
      }
      expect(
        NativeAnimatedImageProvider.debugRetainedBytes,
        lessThanOrEqualTo(16),
      );
      expect(NativeAnimatedImageProvider.debugActiveSequences, 2);
    } finally {
      for (var i = 0; i < streams.length; i++) {
        streams[i].removeListener(listeners[i]);
        await providers[i].evict();
      }
    }
    await _waitForReleasedFrames();
    expect(NativeAnimatedImageProvider.debugRetainedBytes, 0);
    expect(NativeAnimatedImageProvider.debugActiveSequences, 0);
  });

  test('最后监听移除后再次监听重新加载', () async {
    var loads = 0;
    final provider = NativeAnimatedImageProvider.fromBytesProvider(
      tag: '重载',
      loader: () async {
        loads++;
        return _gif;
      },
    );
    final stream = provider.resolve(ImageConfiguration.empty);
    final keepAlive = stream.completer!.keepAlive();
    var ready = Completer<void>();
    final listener = ImageStreamListener(
      (info, _) {
        info.dispose();
        if (!ready.isCompleted) ready.complete();
      },
      onError: (Object error, StackTrace? stack) {
        if (!ready.isCompleted) ready.completeError(error, stack);
      },
    );
    try {
      stream.addListener(listener);
      await ready.future.timeout(const Duration(seconds: 10));
      stream.removeListener(listener);
      await _waitForReleasedFrames();
      expect(NativeAnimatedImageProvider.debugRetainedBytes, 0);
      ready = Completer<void>();
      stream.addListener(listener);
      await ready.future.timeout(const Duration(seconds: 10));
      expect(loads, 2);
    } finally {
      stream.removeListener(listener);
      keepAlive.dispose();
      await provider.evict();
    }
    await _waitForReleasedFrames();
    expect(NativeAnimatedImageProvider.debugRetainedBytes, 0);
  });

  for (final budget in <int?>[null, 0]) {
    test('尺寸键与帧释放（原生预算：$budget）', () async {
      NativeAnimatedImageProvider.debugSetBudgetLimit(budget);
      final provider = NativeAnimatedImageProvider.memory(
        _largeGif,
        tag: '动画',
        cacheWidth: 4,
      );
      expect(provider, isNot(provider.resize(cacheWidth: 2)));
      final stream = provider.resolve(ImageConfiguration.empty);
      final ready = Completer<ImageInfo>();
      final listener = ImageStreamListener(
        (info, _) {
          if (!ready.isCompleted) {
            ready.complete(info);
          } else {
            info.dispose();
          }
        },
        onError: (Object error, StackTrace? stack) {
          if (!ready.isCompleted) ready.completeError(error, stack);
        },
      );
      try {
        stream.addListener(listener);
        final info = await ready.future.timeout(const Duration(seconds: 10));
        try {
          expect(info.image.width, 4);
          expect(info.image.height, 2);
        } finally {
          info.dispose();
        }
        expect(
          NativeAnimatedImageProvider.debugActiveSequences,
          greaterThan(0),
        );
      } finally {
        stream.removeListener(listener);
        await provider.evict();
      }
      await _waitForReleasedFrames();
      expect(NativeAnimatedImageProvider.debugRetainedBytes, 0);
      expect(NativeAnimatedImageProvider.debugActiveSequences, 0);
    });
  }

  test('没有构建帧时也能暂停解码，恢复后重新加载', () async {
    final enabled = ValueNotifier<bool>(true);
    NativeAnimatedImageProvider.animationEnabled = enabled;
    var loads = 0;
    var ready = Completer<void>();
    final provider = NativeAnimatedImageProvider.fromBytesProvider(
      tag: '窗口生命周期',
      loader: () async {
        loads++;
        return _gif;
      },
    );
    final stream = provider.resolve(ImageConfiguration.empty);
    final listener = ImageStreamListener(
      (info, _) {
        info.dispose();
        if (!ready.isCompleted) ready.complete();
      },
      onError: (Object error, StackTrace? stack) {
        if (!ready.isCompleted) ready.completeError(error, stack);
      },
    );
    try {
      stream.addListener(listener);
      await ready.future.timeout(const Duration(seconds: 10));
      enabled.value = false;
      await _waitForReleasedFrames();
      expect(NativeAnimatedImageProvider.debugRetainedBytes, 0);
      ready = Completer<void>();
      enabled.value = true;
      await ready.future.timeout(const Duration(seconds: 10));
      expect(loads, 2);
    } finally {
      stream.removeListener(listener);
      await provider.evict();
      await _waitForReleasedFrames();
      enabled.dispose();
    }
  });

  test('加载中取消不会保留解码结果', () async {
    final source = Completer<Uint8List>();
    final provider = NativeAnimatedImageProvider.fromBytesProvider(
      loader: () => source.future,
      tag: '取消',
    );
    final stream = provider.resolve(ImageConfiguration.empty);
    final listener = ImageStreamListener((info, _) => info.dispose());
    stream.addListener(listener);
    stream.removeListener(listener);
    await provider.evict();
    source.complete(_gif);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(NativeAnimatedImageProvider.debugRetainedBytes, 0);
    expect(NativeAnimatedImageProvider.debugActiveSequences, 0);
  });
}
