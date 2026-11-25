/// Raw FFI bindings to `native_animated_image_codec` (Rust cdylib/staticlib).
///
/// 此文件仅暴露原始 FFI 函数指针,不做任何高层封装。高层 API 见
/// `native_animated_image_ffi.dart`。
library;

import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

// ============== C 函数签名 (与 crates/native_animated_image_codec/src/ffi.rs 对齐) ==============

/// `int32_t native_animated_image_decode(const uint8_t* bytes, uintptr_t len, uint64_t* out_handle)`
typedef NativeDecodeC = Int32 Function(
  Pointer<Uint8> bytes,
  IntPtr len,
  Pointer<Uint64> outHandle,
);
typedef NativeDecode = int Function(
  Pointer<Uint8> bytes,
  int len,
  Pointer<Uint64> outHandle,
);

/// `char* native_animated_image_get_metadata_json(uint64_t handle)`
typedef NativeGetMetadataJsonC = Pointer<Utf8> Function(Uint64 handle);
typedef NativeGetMetadataJson = Pointer<Utf8> Function(int handle);

/// `int32_t native_animated_image_get_frame_rgba(uint64_t handle, uint32_t frame_idx,
///   const uint8_t** out_ptr, uintptr_t* out_len)`
typedef NativeGetFrameRgbaC = Int32 Function(
  Uint64 handle,
  Uint32 frameIdx,
  Pointer<Pointer<Uint8>> outPtr,
  Pointer<IntPtr> outLen,
);
typedef NativeGetFrameRgba = int Function(
  int handle,
  int frameIdx,
  Pointer<Pointer<Uint8>> outPtr,
  Pointer<IntPtr> outLen,
);

/// `void native_animated_image_release(uint64_t handle)`
typedef NativeReleaseC = Void Function(Uint64 handle);
typedef NativeRelease = void Function(int handle);

/// `void native_animated_image_free_string(char* s)`
typedef NativeFreeStringC = Void Function(Pointer<Utf8> s);
typedef NativeFreeString = void Function(Pointer<Utf8> s);

/// `const char* native_animated_image_version()`
typedef NativeVersionC = Pointer<Utf8> Function();
typedef NativeVersion = Pointer<Utf8> Function();

// ============== 错误码 ==============

const int kErrOk = 0;
const int kErrInvalid = -1;
const int kErrUnsupported = -2;
const int kErrDecode = -3;
const int kErrHandleNotFound = -4;
const int kErrFrameOor = -5;
const int kErrPanic = -6;

// ============== DynamicLibrary 加载 ==============

/// 加载 native_animated_image_codec 动态库
///
/// 各平台 binary 名约定(由 `crates/native_animated_image_codec/Cargo.toml` 的 `[lib] name`
/// 决定:`native_animated_image_codec`):
///
/// | 平台    | binary 名                                  | 加载方式                |
/// |--------|--------------------------------------------|------------------------|
/// | iOS    | static lib 链接进 app binary                | DynamicLibrary.process()|
/// | macOS  | libnative_animated_image_codec.dylib       | DynamicLibrary.open    |
/// | Android| libnative_animated_image_codec.so          | DynamicLibrary.open    |
/// | Windows| native_animated_image_codec.dll            | DynamicLibrary.open    |
/// | Linux  | libnative_animated_image_codec.so          | DynamicLibrary.open    |
DynamicLibrary loadNativeAnimatedImageCodec() {
  if (Platform.isIOS) {
    return DynamicLibrary.process();
  }
  if (Platform.isMacOS) {
    return DynamicLibrary.open('libnative_animated_image_codec.dylib');
  }
  if (Platform.isAndroid || Platform.isLinux) {
    return DynamicLibrary.open('libnative_animated_image_codec.so');
  }
  if (Platform.isWindows) {
    return DynamicLibrary.open('native_animated_image_codec.dll');
  }
  throw UnsupportedError(
    'native_animated_image: unsupported platform ${Platform.operatingSystem}',
  );
}

// ============== 函数指针 lookup helper ==============

NativeDecode lookupDecode(DynamicLibrary lib) =>
    lib.lookupFunction<NativeDecodeC, NativeDecode>('native_animated_image_decode');

NativeGetMetadataJson lookupGetMetadataJson(DynamicLibrary lib) =>
    lib.lookupFunction<NativeGetMetadataJsonC, NativeGetMetadataJson>(
      'native_animated_image_get_metadata_json',
    );

NativeGetFrameRgba lookupGetFrameRgba(DynamicLibrary lib) =>
    lib.lookupFunction<NativeGetFrameRgbaC, NativeGetFrameRgba>(
      'native_animated_image_get_frame_rgba',
    );

NativeRelease lookupRelease(DynamicLibrary lib) =>
    lib.lookupFunction<NativeReleaseC, NativeRelease>('native_animated_image_release');

NativeFreeString lookupFreeString(DynamicLibrary lib) =>
    lib.lookupFunction<NativeFreeStringC, NativeFreeString>(
      'native_animated_image_free_string',
    );

NativeVersion lookupVersion(DynamicLibrary lib) =>
    lib.lookupFunction<NativeVersionC, NativeVersion>('native_animated_image_version');
