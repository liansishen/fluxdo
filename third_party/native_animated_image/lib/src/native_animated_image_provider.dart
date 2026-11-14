/// [NativeAnimatedImageProvider] — Flutter [ImageProvider] that decodes
/// animated images (GIF / APNG / animated WebP) via the native Rust codec,
/// bypassing Flutter's built-in Skia multi-frame codec.
///
/// 用法:
///
/// ```dart
/// Image(image: NativeAnimatedImageProvider.memory(gifBytes))
/// Image(image: NativeAnimatedImageProvider.network('https://...'))
/// ```
///
/// 实现要点(参考成熟的 AvifImageProvider 模式):
/// - 单帧场景走 [OneFrameImageStreamCompleter] 快速路径
/// - 多帧场景用 `Timer` 调度帧切换,`hasListeners` 自动暂停/恢复
/// - 解码在 [Isolate.run] background isolate 中跑,避免阻塞 UI
/// - RGBA → ui.Image 逐帧惰性转换:像素拷贝是同步 FFI,一次性全帧转换
///   会把 UI 线程连续占用十几 ms 导致滚动掉帧,见 [_LazyRgbaFrameSequence]
/// - 超大动图(单帧 > [_kMaxNativeDecodePixels] 像素、或 RGBA 总量 >
///   [_kMaxNativeDecodeTotalBytes])不走 Rust 全帧 RGBA 路径 —— 那样
///   要么 UI 线程像素拷贝挤占帧预算,要么全帧解码打爆内存;改走
///   Flutter 内置 codec 流式解码(engine IO 线程解码并按体量缩放,
///   UI 线程零像素拷贝),见 [_CodecFrameSequence]。动图始终播放,
///   体量病态的用更小的解码尺寸([_kTightClampDimension])控制成本
/// - 并发解码限制(避免大量动图同屏解码导致内存峰值)
library;

import 'dart:async';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

import 'ffi/native_animated_image_bindings.dart' show kErrUnsupported;
import 'ffi/native_animated_image_ffi.dart';
import 'utils/semaphore.dart';

/// 限制全局并发解码数,避免多个大动图同时解导致 RAM 峰值
final _decodeSemaphore = AsyncSemaphore(3);

/// 单帧超过这个像素数(1024×1024,一帧 RGBA 4MB)就不走 Rust 全帧解码,
/// 降级到 Flutter 内置 codec 流式路径:
/// - UI 线程的单次同步像素拷贝(`ImmutableBuffer.fromUint8List`)与帧
///   像素量成正比,4MB 约 1~2ms,再大就开始挤占 120Hz 的 8.3ms 帧预算
///   (实测 2048² 阈值下单次拷贝可达 22ms);
/// - Rust 路径是全帧一次性解码,RGBA 会在 Dart heap 常驻到播完一轮,
///   帧多的大图轻松几百 MB,直接触发 GC 风暴。
const int _kMaxNativeDecodePixels = 1024 * 1024;

/// 降级路径的解码尺寸上限(最长边,等比缩放,不放大):内置 codec 流式
/// 播放每轮都要重新解码 + 上传纹理(raster 线程),纹理越大 raster 越痛
/// (实测 2048² 纹理反复上传可把 raster 单帧顶到 76ms)。1280 覆盖任何
/// 实际显示宽度,纹理 ≤6.5MB。
const int _kClampDimension = 1280;

/// Rust 全帧解码的总体量上限(RGBA 字节 = width × height × 4 × 帧数):
/// Rust 路径一次性解出所有帧,总量决定了解码期的内存峰值和播放期
/// ui.Image 全帧常驻的量。单帧尺寸合格但帧数巨大的动图一样是灾难
/// (实测案例:1200×800 × 612 帧 = 2.2GB),超过就走内置 codec 流式。
const int _kMaxNativeDecodeTotalBytes = 48 << 20;

const int _defaultBudgetLimit = 128 << 20;
int _budgetLimit = _defaultBudgetLimit;
int _retainedBytes = 0;
int _activeSequences = 0;

/// 超量动图(RGBA 总量)进一步收紧解码分辨率的门槛:流式播放每轮
/// 循环重解码,CPU 与纹理带宽和总量成正比。产品决策是动图必须能动
/// (不做首帧静态降级),所以对体量病态的样本用更小的解码尺寸
/// ([_kTightClampDimension])换取可持续的解码/上传成本 —— 帖子里
/// 动图的实际显示宽度远小于这个值,视觉无损。
const int _kHugeAnimationTotalBytes = 256 << 20;

/// 超量动图的解码尺寸上限(最长边)
const int _kTightClampDimension = 800;

/// 字节源:bytes / network / file
abstract class _ByteSource {
  Future<Uint8List> load();

  /// 用于 ImageProvider key 相等性
  String get cacheKey;
}

class _MemorySource extends _ByteSource {
  _MemorySource(this.bytes, {required this.tag});

  final Uint8List bytes;
  final String tag;

  @override
  Future<Uint8List> load() async => bytes;

  @override
  String get cacheKey => 'memory:$tag';
}

class _NetworkSource extends _ByteSource {
  _NetworkSource(this.url, {this.headers});

  final String url;
  final Map<String, String>? headers;

  @override
  Future<Uint8List> load() async {
    // 默认实现:用 Flutter 的 NetworkImage 内部机制(HttpClient)
    // 高阶用户(如 fluxdo)应该走自己的 cacheManager,我们在外层提供
    // [NativeAnimatedImageProvider.fromBytesProvider] 让他们包装
    throw UnimplementedError(
      'NativeAnimatedImageProvider.network requires a custom byte loader. '
      'Use NativeAnimatedImageProvider.fromBytesProvider(...) instead, '
      'or wait for built-in HttpClient implementation in v0.2.',
    );
  }

  @override
  String get cacheKey => 'network:$url';
}

class _CustomSource extends _ByteSource {
  _CustomSource(this.loader, {required this.tag});

  final Future<Uint8List> Function() loader;
  final String tag;

  @override
  Future<Uint8List> load() => loader();

  @override
  String get cacheKey => 'custom:$tag';
}

/// Flutter [ImageProvider] implementation backed by the native Rust decoder.
class NativeAnimatedImageProvider
    extends ImageProvider<NativeAnimatedImageProvider> {
  NativeAnimatedImageProvider._(
    this._source, {
    this.scale = 1.0,
    this.cacheWidth,
    this.cacheHeight,
  })  : assert(cacheWidth == null || cacheWidth > 0),
        assert(cacheHeight == null || cacheHeight > 0);

  /// 从已有的字节数据创建 provider。
  ///
  /// [tag] 用于 ImageProvider 相等性判断 —— 相同 tag 的 provider 会共享 Flutter 全局
  /// ImageCache 项。传一个稳定的标识符(如 url、hash、或资源 id)。
  factory NativeAnimatedImageProvider.memory(
    Uint8List bytes, {
    required String tag,
    double scale = 1.0,
    int? cacheWidth,
    int? cacheHeight,
  }) =>
      NativeAnimatedImageProvider._(
        _MemorySource(bytes, tag: tag),
        scale: scale,
        cacheWidth: cacheWidth,
        cacheHeight: cacheHeight,
      );

  /// 从自定义 byte loader 创建 provider(适用于已有 cache_manager 的场景)。
  ///
  /// 这是最灵活的入口 —— 调用方决定从哪里(网络/文件/缓存)拉 bytes。
  factory NativeAnimatedImageProvider.fromBytesProvider({
    required Future<Uint8List> Function() loader,
    required String tag,
    double scale = 1.0,
    int? cacheWidth,
    int? cacheHeight,
  }) =>
      NativeAnimatedImageProvider._(
        _CustomSource(loader, tag: tag),
        scale: scale,
        cacheWidth: cacheWidth,
        cacheHeight: cacheHeight,
      );

  /// (实验)从 URL 创建 provider。当前要求用户自己提供 byte loader,
  /// 见 [fromBytesProvider]。未来版本会内置 HttpClient 实现。
  factory NativeAnimatedImageProvider.network(
    String url, {
    Map<String, String>? headers,
    double scale = 1.0,
    int? cacheWidth,
    int? cacheHeight,
  }) =>
      NativeAnimatedImageProvider._(
        _NetworkSource(url, headers: headers),
        scale: scale,
        cacheWidth: cacheWidth,
        cacheHeight: cacheHeight,
      );

  final _ByteSource _source;
  final double scale;
  final int? cacheWidth;
  final int? cacheHeight;

  /// 宿主窗口可见性；直接停止定时解码，不依赖隐藏窗口继续构建。
  static ValueListenable<bool>? animationEnabled;

  static int get debugRetainedBytes => _retainedBytes;
  static int get debugActiveSequences => _activeSequences;

  /// 仅供测试在没有活跃序列时调整预算；传 null 恢复默认值。
  static void debugSetBudgetLimit(int? bytes) {
    if (_retainedBytes != 0 || (bytes != null && bytes < 0)) {
      throw StateError('预算调整要求没有活跃的原生帧序列');
    }
    _budgetLimit = bytes ?? _defaultBudgetLimit;
  }

  NativeAnimatedImageProvider resize({int? cacheWidth, int? cacheHeight}) =>
      NativeAnimatedImageProvider._(
        _source,
        scale: scale,
        cacheWidth: cacheWidth,
        cacheHeight: cacheHeight,
      );

  /// 首帧产出的全局闸门 hook(宿主 app 可注入,默认 null = 行为不变)。
  ///
  /// Impeller 把"解码完成"与"纹理上传"绑在同一个任务里,提交进与
  /// raster 共用的 GPU 队列 —— 多张图同时挂载时首帧上传集中到达会顶出
  /// raster 大帧。宿主注入闸门(通常是全局信号量的 run 函数)后,
  /// **Rust 路径的首帧** RGBA→ui.Image 转换(纹理上传点)经由闸门执行,
  /// 与宿主其它图片管线统一错峰;**播放中的后续帧不过闸**,动画节奏
  /// 不受影响。
  ///
  /// 内置 codec 路径不走本 hook —— 它经由
  /// [PaintingBinding.instantiateImageCodecWithSize] 创建 codec,宿主若
  /// 在 binding 层做了闸门会自然覆盖;此处再套一层会造成同一信号量的
  /// 嵌套获取(死锁风险)。
  static Future<T> Function<T>(Future<T> Function() task)? firstFrameGate;

  @override
  Future<NativeAnimatedImageProvider> obtainKey(
    ImageConfiguration configuration,
  ) {
    return SynchronousFuture<NativeAnimatedImageProvider>(this);
  }

  @override
  ImageStreamCompleter loadImage(
    NativeAnimatedImageProvider key,
    ImageDecoderCallback decode,
  ) {
    return _NativeAnimatedImageStreamCompleter(
      framesLoader: () => _loadAndDecode(key),
      scale: scale,
      debugLabel: _source.cacheKey,
    );
  }

  /// 从 byte source 加载 → isolate 内 decode → 惰性帧序列
  ///
  /// 这里刻意不把帧转成 ui.Image:RGBA → ui.Image 的像素拷贝是同步 FFI,
  /// 全帧连续转换会把 UI 线程占满几十 ms(CPU profile 实测占 UI isolate
  /// ~20%,滚动中挂载动图直接掉帧)。转换推迟到播放时逐帧进行,
  /// 见 [_LazyRgbaFrameSequence]。
  Future<_FrameSequence> _loadAndDecode(NativeAnimatedImageProvider key) async {
    await _decodeSemaphore.acquire();
    try {
      final bytes = await key._source.load();

      // 超大图前置分流:从文件头嗅探尺寸 + 帧数(GIF / PNG / WebP 的
      // 容器结构都能不解码地数出来),按单帧像素量与总解码体量分流。
      // 单帧超标 → UI 线程像素拷贝太贵;总量超标(单帧不大但帧数巨大,
      // 例 1200×800×612 帧 = 2.2GB)→ Rust 全帧解码直接打爆内存。
      // 两者都走内置 codec 流式播放;体量病态的用更小的解码尺寸。
      final frameBytes4 = _sniffFrameBytes(bytes);
      final sniffed = frameBytes4?.info;
      final totalBytes = frameBytes4?.totalBytes;
      final target = _targetSize(sniffed?.width ?? 1, sniffed?.height ?? 1);

      // 静态图前置分流:容器头就能**确定**无动画的(简单 webp / VP8X
      // 无 ANIM 位 / 无 acTL 的 PNG),直接走内置 codec —— Rust 端本就
      // 不支持静态格式,省一趟 isolate 启动 + Rust 试解 + kErrUnsupported
      // 回程。拿不准的一律不分流,保持原路径。
      if (_isDefinitelyStaticImage(bytes, sniffed?.frames)) {
        return _decodeViaFlutterCodec(
          bytes,
          clampDimension: _clampFor(totalBytes),
        );
      }

      if (sniffed == null ||
          totalBytes == null ||
          totalBytes <= 0 ||
          sniffed.width * sniffed.height > _kMaxNativeDecodePixels ||
          totalBytes > _kMaxNativeDecodeTotalBytes ||
          _retainedBytes + totalBytes * 2 > _budgetLimit) {
        return _decodeViaFlutterCodec(
          bytes,
          clampDimension: _clampFor(totalBytes),
        );
      }
      _retainedBytes += totalBytes * 2;
      var transferred = false;
      try {
        // 在 background isolate 中跑 Rust FFI 解码,避免阻塞 UI 线程。
        // Rust 端只解动图(GIF / APNG / animated WebP / AVIF)+ animated AVIF
        // fallback;静态 WebP / 静态 PNG / 静态 GIF / JPEG 等会返
        // [kErrUnsupported] —— 这种情况 fallback 走 Flutter 内置 codec
        // (见 [_decodeViaFlutterCodec]),保证调用方拿到的 provider
        // 对任何主流图片格式都能出图,不需要在外层再 router。
        DecodedAnimatedImage decoded;
        try {
          decoded = await Isolate.run(() {
            return NativeAnimatedImageFfi.instance.decode(bytes);
          }, debugName: 'NativeAnimatedImage.decode');
        } on NativeAnimatedImageException catch (e) {
          if (e.code == kErrUnsupported) {
            // Rust 不识别的多为静态格式
            return _decodeViaFlutterCodec(
              bytes,
              clampDimension: _clampFor(totalBytes),
            );
          }
          rethrow;
        }

        // 双保险:嗅探失手(罕见容器变体)但实际解出了超标内容,同样降级,
        // 宁可浪费这次后台解码也不能把几十 MB/帧的拷贝压到 UI 线程、或把
        // GB 级的全帧 ui.Image 常驻进内存。
        final decodedPixels = decoded.width * decoded.height;
        final decodedTotal = decodedPixels * 4 * decoded.frames.length;
        if (decodedPixels > _kMaxNativeDecodePixels ||
            decodedTotal > _kMaxNativeDecodeTotalBytes ||
            decodedTotal > totalBytes) {
          return _decodeViaFlutterCodec(
            bytes,
            clampDimension: _clampFor(decodedTotal),
          );
        }

        transferred = true;
        return _LazyRgbaFrameSequence(
          decoded,
          totalBytes * 2,
          target.width!,
          target.height!,
        );
      } finally {
        if (!transferred) _retainedBytes -= totalBytes * 2;
      }
    } finally {
      _decodeSemaphore.release();
    }
  }

  /// 按总体量选择解码尺寸上限:体量未知或常规超标用 [_kClampDimension],
  /// 病态体量(几百 MB+)收紧到 [_kTightClampDimension]。
  static int _clampFor(int? totalBytes) {
    return totalBytes != null && totalBytes > _kHugeAnimationTotalBytes
        ? _kTightClampDimension
        : _kClampDimension;
  }

  /// 内置 codec 路径:Rust 不识别的格式(静态 webp/png/jpeg 等)的兜底,
  /// 以及超大动图的降级通道。
  ///
  /// 解码(含缩放)在 engine IO 线程按帧进行,UI 线程只有一次压缩字节的
  /// 拷贝(几百 KB 级,~1ms)。帧不预取不缓存,由 [_CodecFrameSequence]
  /// 播放时流式拉取 —— 一次性 getNextFrame 全帧常驻对大动图是内存炸弹。
  ///
  /// 静态格式在这条路上不会踩 multi_frame_codec 的 #85831 bug(那个 bug
  /// 只发生在多帧 disposal 路径);超大动图为了不卡 UI 接受这个权衡。
  Future<_FrameSequence> _decodeViaFlutterCodec(
    Uint8List bytes, {
    required int clampDimension,
  }) async {
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    late ui.TargetImageSize targetSize;
    // 经由 PaintingBinding 而非裸 ui.instantiateImageCodecWithSize:
    // 默认 binding 下二者完全等价;宿主 app 若覆写了 binding 的解码
    // 入口(如全局解码并发闸门),这条 fallback 路径(静态 webp/png/
    // jpeg + 超大动图降级)就能被统一纳管,而不是绕开宿主的调度。
    final codec = await PaintingBinding.instance.instantiateImageCodecWithSize(
      buffer,
      getTargetSize: (int intrinsicWidth, int intrinsicHeight) {
        return targetSize = _targetSize(
          intrinsicWidth,
          intrinsicHeight,
          clampDimension: clampDimension,
        );
      },
    );
    return _CodecFrameSequence(codec, targetSize);
  }

  ui.TargetImageSize _targetSize(int width, int height, {int? clampDimension}) {
    var ratio = 1.0;
    if (cacheWidth != null) ratio = math.min(ratio, cacheWidth! / width);
    if (cacheHeight != null) ratio = math.min(ratio, cacheHeight! / height);
    if (clampDimension != null) {
      ratio = math.min(ratio, clampDimension / math.max(width, height));
    }
    return ui.TargetImageSize(
      width: math.max(1, (width * ratio).round()),
      height: math.max(1, (height * ratio).round()),
    );
  }

  /// 把 RGBA Uint8List 转为 ui.Image(用 Flutter 的 decodeImageFromPixels,
  /// 它接受 raw pixel buffer,**不经过 Skia codec**,所以不会踩 multi_frame_codec bug)
  static Future<ui.Image> _rgbaToUiImage(
    Uint8List rgba,
    int width,
    int height,
    int targetWidth,
    int targetHeight,
  ) {
    final completer = Completer<ui.Image>();
    ui.decodeImageFromPixels(
      rgba,
      width,
      height,
      ui.PixelFormat.rgba8888,
      (image) => completer.complete(image),
      targetWidth: targetWidth,
      targetHeight: targetHeight,
    );
    return completer.future;
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is NativeAnimatedImageProvider &&
        other._source.cacheKey == _source.cacheKey &&
        other.scale == scale &&
        other.cacheWidth == cacheWidth &&
        other.cacheHeight == cacheHeight;
  }

  @override
  int get hashCode =>
      Object.hash(_source.cacheKey, scale, cacheWidth, cacheHeight);

  @override
  String toString() =>
      'NativeAnimatedImageProvider(${_source.cacheKey}, scale: $scale)';
}

/// 单帧封装:ui.Image + 该帧 delay
class _RenderableFrame {
  _RenderableFrame({required this.image, required this.delay});

  final ui.Image image;
  final Duration delay;
}

/// 帧序列抽象:completer 按播放顺序取帧的统一入口
///
/// 顺序语义(而不是随机访问)是刻意的:内置 codec 只能顺序解码
/// ([_CodecFrameSequence]),而动画播放恰好是顺序 + 循环,两者天然匹配。
///
/// 两个实现:
/// - [_LazyRgbaFrameSequence]:Rust 解码产物,RGBA → ui.Image 按需转换
/// - [_CodecFrameSequence]:内置 codec 流式解码(fallback / 超大图降级)
abstract class _FrameSequence {
  int get frameCount;

  /// 取下一帧(播放推进,循环回绕由实现负责)。
  ///
  /// 返回的 frame 只保证在下一次 [nextFrame] 调用前有效;需要长期持有
  /// 必须 clone([_NativeAnimatedImageStreamCompleter] 的 setImage 就是
  /// clone 语义,天然满足)。
  Future<_RenderableFrame> nextFrame();

  /// 提示实现:提前准备下一帧(在当前帧的 delay 窗口里后台完成,
  /// 到点的 [nextFrame] 就能立即命中)。失败静默 —— [nextFrame] 会重试
  /// 并由调用方上报。
  void prefetchNext() {}
  void dispose();
}

/// Rust 解码路径的惰性帧序列:持有 RGBA 源数据,播放到哪帧转哪帧
///
/// 收益(相对一次性全帧转换):
/// - 挂载时只需转第 1 帧(+预转 1 帧),后续转换摊到播放过程的帧间隙里;
///   快速滚过的动图只花 1-2 帧的转换成本
/// - engine 侧图像内存从"全帧常驻"降为"已播放过的帧";单帧 RGBA 源
///   数据转换完立即释放
/// - 每帧只转换一次(永久缓存),循环播放第二轮起零成本,与旧行为一致
class _LazyRgbaFrameSequence implements _FrameSequence {
  _LazyRgbaFrameSequence(
    DecodedAnimatedImage decoded,
    this._reserved,
    this._targetWidth,
    this._targetHeight,
  )   : _width = decoded.width,
        _height = decoded.height,
        _rgba = [for (final f in decoded.frames) f.rgba],
        _delays = [for (final f in decoded.frames) f.delay],
        _converted =
            List<_RenderableFrame?>.filled(decoded.frames.length, null) {
    _activeSequences++;
  }
  final int _reserved;
  final int _targetWidth;
  final int _targetHeight;
  bool _disposed = false;
  bool _released = false;

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    for (var i = 0; i < _rgba.length; i++) {
      _rgba[i] = null;
      _converted[i]?.image.dispose();
      _converted[i] = null;
    }
    _releaseIfDone();
  }

  void _releaseIfDone() {
    if (_disposed && _pending.isEmpty && !_released) {
      _released = true;
      _retainedBytes -= _reserved;
      _activeSequences--;
    }
  }

  final int _width;
  final int _height;

  /// 未转换帧的 RGBA 源数据;对应帧转换完成后置 null 让 GC 回收
  final List<Uint8List?> _rgba;
  final List<Duration> _delays;

  /// 已转换的帧(永久缓存)
  final List<_RenderableFrame?> _converted;

  /// 转换中的帧,避免 [nextFrame] 与 [prefetchNext] 对同一帧重复转换
  final Map<int, Future<_RenderableFrame>> _pending = {};

  /// 下一次 [nextFrame] 要交付的帧号
  int _cursor = 0;

  @override
  int get frameCount => _converted.length;

  @override
  Future<_RenderableFrame> nextFrame() {
    final index = _cursor;
    _cursor = (_cursor + 1) % frameCount;
    return _frameAt(index);
  }

  @override
  void prefetchNext() {
    unawaited(
      _frameAt(_cursor)
          .then<void>((_) {}, onError: (Object _, StackTrace _s) {}),
    );
  }

  Future<_RenderableFrame> _frameAt(int index) {
    final cached = _converted[index];
    if (cached != null) {
      return SynchronousFuture<_RenderableFrame>(cached);
    }
    return _pending.putIfAbsent(index, () => _convert(index));
  }

  Future<_RenderableFrame> _convert(int index) async {
    try {
      // 让出一个完整 event loop turn(microtask 让步不够):像素拷贝是
      // 同步 FFI,不让步的话同屏多个动图的转换会在同一个 turn 里连续
      // 执行,重新把 UI 线程占满;隔开后 vsync / 触摸事件能插进来。
      await Future<void>.delayed(Duration.zero);
      if (_disposed) throw StateError('动画帧序列已释放');
      Future<ui.Image> produce() {
        if (_disposed) throw StateError('动画帧序列已释放');
        return NativeAnimatedImageProvider._rgbaToUiImage(
          _rgba[index]!,
          _width,
          _height,
          _targetWidth,
          _targetHeight,
        );
      }

      // 首帧(挂载瞬态,多图同屏时上传集中到达)过宿主注入的全局
      // 闸门错峰;后续帧在播放节奏里逐帧到来,天然稀疏,不过闸。
      final gate = NativeAnimatedImageProvider.firstFrameGate;
      final image =
          (index == 0 && gate != null) ? await gate(produce) : await produce();
      if (_disposed) {
        image.dispose();
        throw StateError('动画帧序列已释放');
      }
      final frame = _RenderableFrame(image: image, delay: _delays[index]);
      _converted[index] = frame;
      _rgba[index] = null;
      return frame;
    } finally {
      // 成功后 _frameAt 走 _converted 缓存;失败后允许下次重试
      _pending.remove(index);
      _releaseIfDone();
    }
  }
}

/// 内置 codec 的流式帧序列:帧不缓存,播放到哪解到哪
///
/// 解码(含降采样)发生在 engine IO 线程,UI 线程零像素拷贝 —— 超大
/// 动图的唯一可行姿势。代价是循环播放每一轮都重新解码(CPU 换内存,
/// 与 Flutter 自带 [MultiFrameImageStreamCompleter] 的行为一致)。
///
/// [ui.Codec.getNextFrame] 播放到末帧后自动回绕,与 [_FrameSequence]
/// 的顺序语义直接对齐。
class _CodecFrameSequence implements _FrameSequence {
  _CodecFrameSequence(this._codec, this._targetSize)
      : frameCount = _codec.frameCount {
    _activeSequences++;
  }

  final ui.Codec _codec;
  final ui.TargetImageSize _targetSize;

  @override
  final int frameCount;

  /// 预取中/已预取还未被消费的帧
  Future<_RenderableFrame>? _prefetched;

  /// 上一次交付出去的帧:下一次推进时 dispose(那时它的 clone 早已上屏)
  ui.Image? _lastDelivered;

  /// 单帧图在首次取帧后就再也用不到 codec 了
  bool _disposed = false;
  bool _codecDisposed = false;
  int _inFlight = 0;

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _lastDelivered?.dispose();
    _lastDelivered = null;
    _prefetched = null;
    _disposeCodecIfReady();
  }

  void _disposeCodecIfReady() {
    if (_disposed && _inFlight == 0 && !_codecDisposed) {
      _codecDisposed = true;
      _codec.dispose();
      _activeSequences--;
    }
  }

  @override
  Future<_RenderableFrame> nextFrame() {
    final pending = _prefetched ?? _advance();
    _prefetched = null;
    return pending;
  }

  @override
  void prefetchNext() {
    if (_disposed) return;
    _prefetched ??= _advance();
    unawaited(
      _prefetched!.then<void>((_) {}, onError: (Object _, StackTrace _s) {}),
    );
  }

  Future<_RenderableFrame> _advance() async {
    _inFlight++;
    try {
      final info = await _codec.getNextFrame();
      var image = info.image;
      final width = _targetSize.width!;
      final height = _targetSize.height!;
      // GIF 等引擎 codec 可能忽略目标尺寸；只在确实超限时缩小当前帧。
      if (image.width > width || image.height > height) {
        final recorder = ui.PictureRecorder();
        ui.Canvas(recorder).drawImageRect(
          image,
          ui.Rect.fromLTWH(
              0, 0, image.width.toDouble(), image.height.toDouble()),
          ui.Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
          ui.Paint()..filterQuality = ui.FilterQuality.medium,
        );
        final picture = recorder.endRecording();
        try {
          image = await picture.toImage(width, height);
        } finally {
          picture.dispose();
          info.image.dispose();
        }
      }
      if (_disposed) {
        image.dispose();
        throw StateError('动画帧序列已释放');
      }
      _lastDelivered?.dispose();
      _lastDelivered = image;
      return _RenderableFrame(image: image, delay: info.duration);
    } finally {
      _inFlight--;
      _disposeCodecIfReady();
    }
  }
}

/// 嗅探尺寸与帧数并折算 RGBA 总体量。
///
/// 帧计数上限取"足以判定 [_kHugeAnimationTotalBytes]"的帧数 —— 病态
/// 样本(几百帧)只需扫到上限即停,嗅探成本与阈值成正比而不是与
/// 文件帧数成正比。frames 未知(非动图容器 / 结构异常)时
/// totalBytes 为 null,交由 Rust 解码后的双保险兜底。
({({int width, int height, int? frames}) info, int? totalBytes})?
    _sniffFrameBytes(Uint8List bytes) {
  // 先只读尺寸(帧数上限依赖单帧体量)
  final probe = _sniffImageSize(bytes, frameCountLimit: 1);
  if (probe == null) return null;
  final frameBytes = probe.width * probe.height * 4;
  if (frameBytes <= 0) return (info: probe, totalBytes: null);
  final limit = _kHugeAnimationTotalBytes ~/ frameBytes + 2;
  final info = _sniffImageSize(bytes, frameCountLimit: limit)!;
  final frames = info.frames;
  return (info: info, totalBytes: frames == null ? null : frameBytes * frames);
}

/// 从文件头嗅探图片像素尺寸与帧数,拿不准就返回 null(交给正常解码路径)。
///
/// 只覆盖会走 Rust 解码的三种容器 —— GIF / PNG(含 APNG)/ WebP。
/// 尺寸躺在头部固定偏移上;帧数通过遍历容器块结构获得(不解码像素),
/// 并以 [frameCountLimit] 为上限提前终止 —— 判断体量阈值只需要知道
/// "至少有多少帧",病态样本(600+ 帧)也只扫到上限即停。
({int width, int height, int? frames})? _sniffImageSize(
  Uint8List b, {
  int frameCountLimit = 1 << 30,
}) {
  if (b.length < 10) return null;
  // GIF87a / GIF89a
  if (b[0] == 0x47 && b[1] == 0x49 && b[2] == 0x46 && b[3] == 0x38) {
    final w = b[6] | (b[7] << 8);
    final h = b[8] | (b[9] << 8);
    return (width: w, height: h, frames: _countGifFrames(b, frameCountLimit));
  }
  // PNG / APNG:\x89PNG\r\n\x1a\n + IHDR
  if (b.length >= 24 &&
      b[0] == 0x89 &&
      b[1] == 0x50 &&
      b[2] == 0x4E &&
      b[3] == 0x47) {
    final w = (b[16] << 24) | (b[17] << 16) | (b[18] << 8) | b[19];
    final h = (b[20] << 24) | (b[21] << 16) | (b[22] << 8) | b[23];
    return (width: w, height: h, frames: _countApngFrames(b));
  }
  // RIFF....WEBP + VP8X
  if (b.length >= 30 &&
      b[0] == 0x52 &&
      b[1] == 0x49 &&
      b[2] == 0x46 &&
      b[3] == 0x46 &&
      b[8] == 0x57 &&
      b[9] == 0x45 &&
      b[10] == 0x42 &&
      b[11] == 0x50 &&
      b[12] == 0x56 &&
      b[13] == 0x50 &&
      b[14] == 0x38 &&
      b[15] == 0x58) {
    final w = 1 + (b[24] | (b[25] << 8) | (b[26] << 16));
    final h = 1 + (b[27] | (b[28] << 8) | (b[29] << 16));
    return (width: w, height: h, frames: _countWebpFrames(b, frameCountLimit));
  }
  return null;
}

/// 从容器头判定"**确定**是静态图"(拿不准一律返回 false,交给 Rust
/// 正常路径,决不误伤动图):
/// - 简单 webp(chunk 直接是 `VP8 `/`VP8L`,无 VP8X 扩展):规格上
///   不可能携带动画
/// - VP8X webp:flags 的 ANIM 位(0x02)为 0
/// - PNG:acTL 缺失([_countApngFrames] 返回 1)
///
/// GIF 不在此判定(静态 GIF 罕见,Rust 端本来就能解,不值得引入
/// 误判风险)。
bool _isDefinitelyStaticImage(Uint8List b, int? sniffedFrames) {
  // RIFF....WEBP
  if (b.length >= 21 &&
      b[0] == 0x52 &&
      b[1] == 0x49 &&
      b[2] == 0x46 &&
      b[3] == 0x46 &&
      b[8] == 0x57 &&
      b[9] == 0x45 &&
      b[10] == 0x42 &&
      b[11] == 0x50 &&
      b[12] == 0x56 &&
      b[13] == 0x50 &&
      b[14] == 0x38) {
    // 'VP8 ' (lossy) / 'VP8L' (lossless):无 VP8X = 必静态
    if (b[15] == 0x20 || b[15] == 0x4C) return true;
    // 'VP8X':byte 20 是 flags,ANIM 位 0x02
    if (b[15] == 0x58 && (b[20] & 0x02) == 0) return true;
    return false;
  }
  // PNG:嗅探已遍历 chunk,acTL 缺失时帧数为 1
  if (b.length >= 8 && b[0] == 0x89 && b[1] == 0x50 && sniffedFrames == 1) {
    return true;
  }
  return false;
}

/// 遍历 GIF block 结构数 image descriptor(0x2C),最多数到 [limit]。
/// 结构异常时返回 null，避免在帧数不确定时预留不足。
int? _countGifFrames(Uint8List b, int limit) {
  if (b.length < 14) return null;
  var i = 13;
  final packed = b[10];
  if (packed & 0x80 != 0) i += 3 * (2 << (packed & 7)); // 全局色表
  var frames = 0;
  while (i < b.length && frames < limit) {
    final c = b[i];
    if (c == 0x3B) return frames > 0 ? frames : null;
    if (c == 0x21) {
      // extension: 跳过标签 + 子块链
      i += 2;
      while (i < b.length && b[i] != 0) {
        i += b[i] + 1;
      }
      if (i >= b.length) return null;
      i += 1;
    } else if (c == 0x2C) {
      // image descriptor
      frames++;
      i += 9;
      if (i >= b.length) return null;
      final p = b[i];
      i += 1;
      if (p & 0x80 != 0) i += 3 * (2 << (p & 7)); // 局部色表
      i += 1; // LZW min code size
      while (i < b.length && b[i] != 0) {
        i += b[i] + 1;
      }
      if (i >= b.length) return null;
      i += 1;
    } else {
      return null;
    }
  }
  return frames >= limit ? frames : null;
}

/// PNG chunk 遍历找 acTL(APNG 动画控制块,位于 IDAT 之前),
/// 返回其 num_frames;没有 acTL 的静态 PNG 返回 1。
int? _countApngFrames(Uint8List b) {
  var i = 8;
  while (i + 8 <= b.length) {
    final len = (b[i] << 24) | (b[i + 1] << 16) | (b[i + 2] << 8) | b[i + 3];
    final t0 = b[i + 4], t1 = b[i + 5], t2 = b[i + 6], t3 = b[i + 7];
    if (t0 == 0x61 && t1 == 0x63 && t2 == 0x54 && t3 == 0x4C) {
      // acTL
      if (i + 12 > b.length) return null;
      return (b[i + 8] << 24) | (b[i + 9] << 16) | (b[i + 10] << 8) | b[i + 11];
    }
    // IDAT / IEND:acTL 必在其前,到这还没有就是静态 PNG
    if ((t0 == 0x49 && t1 == 0x44 && t2 == 0x41 && t3 == 0x54) ||
        (t0 == 0x49 && t1 == 0x45 && t2 == 0x4E && t3 == 0x44)) {
      return 1;
    }
    i += 12 + len;
  }
  return null;
}

/// RIFF chunk 遍历数 ANMF(动画帧),最多数到 [limit]。
int? _countWebpFrames(Uint8List b, int limit) {
  var i = 12;
  var frames = 0;
  while (i + 8 <= b.length && frames < limit) {
    final isAnmf = b[i] == 0x41 &&
        b[i + 1] == 0x4E &&
        b[i + 2] == 0x4D &&
        b[i + 3] == 0x46;
    final len =
        b[i + 4] | (b[i + 5] << 8) | (b[i + 6] << 16) | (b[i + 7] << 24);
    if (isAnmf) frames++;
    i += 8 + len + (len & 1);
  }
  return frames > 0 ? frames : null;
}

/// 多帧动画的 [ImageStreamCompleter] —— Timer 调度 + hasListeners 暂停
///
/// 100% 参考 fluxdo 的 _AvifAnimatedImageStreamCompleter 模式,经过项目实战验证。
///
/// 帧的取用走 [_FrameSequence.nextFrame](顺序惰性):显示当前帧时通过
/// [_FrameSequence.prefetchNext] 预备下一帧,Timer 到点后基本都能立即
/// 命中,动画节奏不受转换/解码影响。
class _NativeAnimatedImageStreamCompleter extends ImageStreamCompleter {
  _NativeAnimatedImageStreamCompleter({
    required Future<_FrameSequence> Function() framesLoader,
    required this.scale,
    this.debugLabel,
  }) : _framesLoader = framesLoader;

  final Future<_FrameSequence> Function() _framesLoader;
  final double scale;
  final String? debugLabel;
  final ValueListenable<bool>? _animationEnabled =
      NativeAnimatedImageProvider.animationEnabled;
  _FrameSequence? _sequence;
  Timer? _timer;
  int _generation = 0;
  bool _disposed = false;

  void _start() {
    final generation = ++_generation;
    _framesLoader().then(
      (sequence) {
        if (_disposed || !hasListeners || generation != _generation) {
          sequence.dispose();
          return;
        }
        if (sequence.frameCount == 0) {
          sequence.dispose();
          reportError(
            exception: StateError('动画没有帧'),
            stack: StackTrace.current,
          );
          return;
        }
        _sequence = sequence;
        unawaited(_emit(sequence, generation));
      },
      onError: (Object error, StackTrace stack) {
        if (!_disposed && generation == _generation) {
          reportError(
            context: ErrorDescription('解码动画失败: $debugLabel'),
            exception: error,
            stack: stack,
          );
        }
      },
    );
  }

  Future<void> _emit(_FrameSequence sequence, int generation) async {
    try {
      final frame = await sequence.nextFrame();
      if (_disposed || !hasListeners || generation != _generation) return;
      setImage(ImageInfo(image: frame.image.clone(), scale: scale));
      // 缓存首帧监听会在 setImage 回调中撤销，不能继续预取或预约定时器。
      if (_disposed || !hasListeners || generation != _generation) return;
      if (sequence.frameCount > 1) {
        sequence.prefetchNext();
        final delay = frame.delay.inMilliseconds > 0
            ? frame.delay
            : const Duration(milliseconds: 100);
        _timer = Timer(delay, () => unawaited(_emit(sequence, generation)));
      }
    } catch (error, stack) {
      if (!_disposed && generation == _generation) {
        reportError(
          context: ErrorDescription('读取动画帧失败: $debugLabel'),
          exception: error,
          stack: stack,
        );
      }
    }
  }

  void _onAnimationChanged() {
    if (_disposed || !hasListeners) return;
    _release();
    if (_animationEnabled?.value ?? true) _start();
  }

  void _release() {
    _generation++;
    _timer?.cancel();
    _timer = null;
    _sequence?.dispose();
    _sequence = null;
  }

  @override
  void addListener(ImageStreamListener listener) {
    final hadListeners = hasListeners;
    super.addListener(listener);
    if (!hadListeners && hasListeners && !_disposed) {
      _animationEnabled?.addListener(_onAnimationChanged);
      if (_animationEnabled?.value ?? true) _start();
    }
  }

  @override
  void removeListener(ImageStreamListener listener) {
    super.removeListener(listener);
    if (!hasListeners) {
      _animationEnabled?.removeListener(_onAnimationChanged);
      _release();
    }
  }

  @override
  void onDisposed() {
    _disposed = true;
    _animationEnabled?.removeListener(_onAnimationChanged);
    _release();
    super.onDisposed();
  }
}
