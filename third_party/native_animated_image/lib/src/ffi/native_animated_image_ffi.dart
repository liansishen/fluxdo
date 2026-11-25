/// High-level FFI wrapper around `native_animated_image_codec`.
///
/// 提供安全的 dart API:输入 bytes → 输出 [DecodedAnimatedImage] (含全部帧的 RGBA copy
/// + 元数据)。
///
/// 设计上把 Rust handle 的生命周期完全封装在 [DecodedAnimatedImage] 内部:
/// dart 端拿到的是已 copy 出来的 Uint8List 帧数据,Rust handle 在 [decode] 返回前就 release。
/// 这样避免了 dart ↔ Rust 之间长期跨边界持有指针带来的安全问题(GC 移动 / 生命周期错乱)。
library;

import 'dart:convert';
import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'native_animated_image_bindings.dart';

/// 解码后的动图(全帧 RGBA + 元数据)
class DecodedAnimatedImage {
  DecodedAnimatedImage({
    required this.width,
    required this.height,
    required this.loopCount,
    required this.frames,
  });

  /// 画布宽度(像素)
  final int width;

  /// 画布高度(像素)
  final int height;

  /// 循环次数:0 = 无限循环, N = 播放 N+1 次
  final int loopCount;

  /// 所有帧(已按 disposal/transparency 合成全尺寸 RGBA)
  final List<AnimatedFrame> frames;
}

class AnimatedFrame {
  AnimatedFrame({required this.rgba, required this.delay});

  /// 全尺寸 RGBA 数据(已 copy 出来,长度 = width * height * 4)
  final Uint8List rgba;

  /// 该帧的展示时长
  final Duration delay;
}

/// FFI 异常
class NativeAnimatedImageException implements Exception {
  NativeAnimatedImageException(this.code, this.message);

  final int code;
  final String message;

  @override
  String toString() => 'NativeAnimatedImageException(code=$code, message=$message)';
}

/// FFI singleton — 懒加载 binary 并 cache 函数指针
class NativeAnimatedImageFfi {
  NativeAnimatedImageFfi._();
  static final NativeAnimatedImageFfi instance = NativeAnimatedImageFfi._();

  DynamicLibrary? _lib;
  NativeDecode? _decode;
  NativeGetMetadataJson? _getMetadataJson;
  NativeGetFrameRgba? _getFrameRgba;
  NativeRelease? _release;
  NativeFreeString? _freeString;
  NativeVersion? _version;

  void _ensureLoaded() {
    if (_lib != null) return;
    final lib = loadNativeAnimatedImageCodec();
    _decode = lookupDecode(lib);
    _getMetadataJson = lookupGetMetadataJson(lib);
    _getFrameRgba = lookupGetFrameRgba(lib);
    _release = lookupRelease(lib);
    _freeString = lookupFreeString(lib);
    _version = lookupVersion(lib);
    _lib = lib; // 最后赋值 _lib,确保上述 lookup 全部成功后才认为 loaded
  }

  /// 返回 native binary 的版本字符串(如 "0.1.0")
  String version() {
    _ensureLoaded();
    final ptr = _version!();
    if (ptr == nullptr) return 'unknown';
    return ptr.toDartString();
  }

  /// 解码动图字节流,返回完整解码结果。
  ///
  /// 该方法把 Rust handle 的整个生命周期封装在内部:
  ///   1. 调 `native_animated_image_decode` 拿 handle
  ///   2. 调 `get_metadata_json` 拿元数据
  ///   3. 对每一帧调 `get_frame_rgba` 拿 RGBA 指针 → copy 到 dart 端 Uint8List
  ///   4. 调 `native_animated_image_release` 释放 handle
  ///
  /// 即使中间抛异常也会保证 release(try/finally)。
  ///
  /// Throws [NativeAnimatedImageException] on decode failure.
  DecodedAnimatedImage decode(Uint8List bytes) {
    _ensureLoaded();

    if (bytes.isEmpty) {
      throw NativeAnimatedImageException(kErrInvalid, 'empty input bytes');
    }

    // 1. 把 dart bytes 拷到 native 堆,调 decode
    final inputPtr = malloc<Uint8>(bytes.length);
    final inputBytes = inputPtr.asTypedList(bytes.length);
    inputBytes.setAll(0, bytes);

    final outHandlePtr = malloc<Uint64>();
    int handle = 0;

    try {
      final rc = _decode!(inputPtr, bytes.length, outHandlePtr);
      if (rc != kErrOk) {
        throw NativeAnimatedImageException(rc, _errorMessageFor(rc));
      }
      handle = outHandlePtr.value;
      if (handle == 0) {
        throw NativeAnimatedImageException(
          kErrDecode,
          'decode returned 0 handle',
        );
      }

      // 2. 拿元数据
      final metadata = _readMetadata(handle);

      // 3. 拷每一帧 RGBA
      final frames = <AnimatedFrame>[];
      for (var i = 0; i < metadata.frameCount; i++) {
        final rgba = _readFrameRgba(handle, i);
        frames.add(AnimatedFrame(
          rgba: rgba,
          delay: Duration(milliseconds: metadata.frames[i].delayMs),
        ));
      }

      return DecodedAnimatedImage(
        width: metadata.width,
        height: metadata.height,
        loopCount: metadata.loopCount,
        frames: frames,
      );
    } finally {
      // 确保 handle 被释放(即使中间抛了异常)
      if (handle != 0) {
        _release!(handle);
      }
      malloc.free(outHandlePtr);
      malloc.free(inputPtr);
    }
  }

  /// 读 metadata JSON 并解析
  _Metadata _readMetadata(int handle) {
    final ptr = _getMetadataJson!(handle);
    if (ptr == nullptr) {
      throw NativeAnimatedImageException(
        kErrDecode,
        'get_metadata_json returned null',
      );
    }
    try {
      final jsonStr = ptr.toDartString();
      final parsed = jsonDecode(jsonStr) as Map<String, dynamic>;
      return _Metadata.fromJson(parsed);
    } finally {
      _freeString!(ptr);
    }
  }

  /// 读某帧 RGBA 数据(从 native 指针 copy 到 dart Uint8List)
  Uint8List _readFrameRgba(int handle, int frameIdx) {
    final outPtr = malloc<Pointer<Uint8>>();
    final outLen = malloc<IntPtr>();
    try {
      final rc = _getFrameRgba!(handle, frameIdx, outPtr, outLen);
      if (rc != kErrOk) {
        throw NativeAnimatedImageException(rc, _errorMessageFor(rc));
      }
      final ptr = outPtr.value;
      final len = outLen.value;
      if (ptr == nullptr || len == 0) {
        throw NativeAnimatedImageException(
          kErrDecode,
          'get_frame_rgba returned null/empty pointer',
        );
      }
      // 这里必须 copy(Uint8List.fromList 或 .asTypedList(...).sublist 都行)
      // 因为 ptr 指向的 native 内存归 handle 所有,我们 release handle 后就失效
      return Uint8List.fromList(ptr.asTypedList(len));
    } finally {
      malloc.free(outPtr);
      malloc.free(outLen);
    }
  }

  static String _errorMessageFor(int code) {
    switch (code) {
      case kErrInvalid:
        return 'invalid input';
      case kErrUnsupported:
        return 'unsupported format';
      case kErrDecode:
        return 'decode error';
      case kErrHandleNotFound:
        return 'handle not found';
      case kErrFrameOor:
        return 'frame index out of range';
      case kErrPanic:
        return 'decoder panicked (malformed input)';
      default:
        return 'unknown error';
    }
  }
}

class _Metadata {
  _Metadata({
    required this.width,
    required this.height,
    required this.loopCount,
    required this.frameCount,
    required this.frames,
  });

  factory _Metadata.fromJson(Map<String, dynamic> json) {
    final frames = (json['frames'] as List<dynamic>)
        .map((e) => _FrameMeta.fromJson(e as Map<String, dynamic>))
        .toList(growable: false);
    return _Metadata(
      width: (json['width'] as num).toInt(),
      height: (json['height'] as num).toInt(),
      loopCount: (json['loop_count'] as num).toInt(),
      frameCount: (json['frame_count'] as num).toInt(),
      frames: frames,
    );
  }

  final int width;
  final int height;
  final int loopCount;
  final int frameCount;
  final List<_FrameMeta> frames;
}

class _FrameMeta {
  _FrameMeta({required this.delayMs});

  factory _FrameMeta.fromJson(Map<String, dynamic> json) {
    return _FrameMeta(delayMs: (json['delay_ms'] as num).toInt());
  }

  final int delayMs;
}
