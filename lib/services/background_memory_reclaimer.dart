import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:fluxdo_render/fluxdo_render.dart' show FlattenCache;
import 'package:native_animated_image/native_animated_image.dart';

import '../providers/topic_detail/detail_memory_cache.dart';
import '../widgets/post/post_item/render_parse_cache.dart';
import 'app_logger.dart';
import 'image_stream_lifecycle.dart';

/// 失焦先停播，持续后台后只回收可重建缓存，不销毁页面仍持有的图片。
class BackgroundMemoryReclaimer {
  BackgroundMemoryReclaimer({required this.imageCache});

  static const gracePeriod = Duration(seconds: 15);
  static const backgroundImageCacheBytes = 32 * 1024 * 1024;

  final ImageCache imageCache;
  Timer? _timer;
  int? _foregroundImageCacheBytes;
  AppLifecycleState? _state;

  void handleLifecycleState(AppLifecycleState? state) {
    _state = state;
    switch (state) {
      case null:
      case AppLifecycleState.resumed:
        _restore();
      case AppLifecycleState.inactive:
      case AppLifecycleState.hidden:
        // inactive → hidden 不重置倒计时，避免状态切换延长保留时间。
        if (_foregroundImageCacheBytes == null) {
          _timer ??= Timer(gracePeriod, _reclaim);
        }
      case AppLifecycleState.paused:
        // 移动端即将挂起 isolate，不能指望十五秒后的定时器还能执行。
        _reclaim();
      case AppLifecycleState.detached:
        _timer?.cancel();
        _timer = null;
    }
  }

  void _reclaim() {
    _timer?.cancel();
    _timer = null;
    if (_foregroundImageCacheBytes != null) return;
    _foregroundImageCacheBytes = imageCache.maximumSizeBytes;
    final beforeBytes = imageCache.currentSizeBytes;
    final beforeRss = ProcessInfo.currentRss;
    final reason = _state?.name;

    // 缩减 LRU 而非清 liveImages；在用图片、当前帧和后台下载仍然有效。
    imageCache.maximumSizeBytes = math.min(
      imageCache.maximumSizeBytes,
      backgroundImageCacheBytes,
    );
    TopicDetailMemoryCache.clear();
    RenderParseCache.clear();
    FlattenCache.evictAll();

    final binding = WidgetsBinding.instance;
    // ImageCache 的原生引用延迟到 post-frame 才释放。隐藏窗口没有 vsync，
    // 因此请求一次维护帧完成释放，不能只让缓存计数下降而留下原生图片。
    binding.addPostFrameCallback((_) {
      AppLogger.info(
        '持续后台已缩减图片缓存并释放可重建内容缓存',
        tag: 'Memory',
        fields: {
          'type': 'performance',
          'event': 'background_memory_reclaim',
          'reason': reason,
          'imageCacheBeforeBytes': beforeBytes,
          'imageCacheAfterBytes': imageCache.currentSizeBytes,
          'imageCacheLimitBytes': imageCache.maximumSizeBytes,
          'liveImages': imageCache.liveImageCount,
          'pendingImages': imageCache.pendingImageCount,
          'nativeAnimatedRetainedBytes':
              NativeAnimatedImageProvider.debugRetainedBytes,
          'rssBeforeBytes': beforeRss,
          'rssAfterBytes': ProcessInfo.currentRss,
        },
      );
    }, debugLabel: 'BackgroundMemoryReclaimer.release');
    ManagedImageCache.scheduleDisposalFrame();
  }

  void _restore() {
    _timer?.cancel();
    _timer = null;
    final foregroundBytes = _foregroundImageCacheBytes;
    _foregroundImageCacheBytes = null;
    if (foregroundBytes != null) {
      imageCache.maximumSizeBytes = foregroundBytes;
    }
  }

  void dispose() => _restore();
}
