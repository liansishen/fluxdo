/// Native (Rust) decoder & renderer for animated GIF / APNG / WebP.
///
/// Bypasses Flutter's built-in Skia multi-frame codec to avoid long-standing
/// upstream bugs ([flutter/flutter#85831](https://github.com/flutter/flutter/issues/85831),
/// [flutter/flutter#94205](https://github.com/flutter/flutter/issues/94205))
/// that cause `Could not getPixels for frame N` errors on certain
/// disposal/transparency combinations.
library native_animated_image;

export 'src/native_animated_image_provider.dart' show NativeAnimatedImageProvider;
export 'src/ffi/native_animated_image_ffi.dart'
    show
        DecodedAnimatedImage,
        AnimatedFrame,
        NativeAnimatedImageException,
        NativeAnimatedImageFfi;
