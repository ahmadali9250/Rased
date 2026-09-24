/// Camera frame → model input, in pure Dart (no Flutter, no FFI) so the
/// geometry can be unit-tested and benchmarked on the desktop VM.
///
/// One call to [FrameSampler.fill] does, in a single pass over the content
/// rectangle:
///  * letterboxing to the model input size (Ultralytics grey 114 padding);
///  * rotation of the raw sensor frame to upright (0/90/180/270° clockwise);
///  * optional 2×2 luma box filter when downscaling ≥ [boxFilterMinScale]×
///    (anti-aliasing, closer to the linear/area resize used in training);
///  * YUV420 (planar or semi-planar), BGRA or packed RGB → RGB;
///  * normalisation to float 0–1, or quantisation to int8/uint8.
///
/// Index scheme: for every rotation exactly one of (source x, source y)
/// depends only on the target column and the other only on the target row,
/// so a sample's byte index is `rowA + colA[tx]` and its chroma index is
/// `rowB + colB[tx]` — two adds per pixel, no multiplies. Padding is constant
/// per geometry and is written once when the maps are (re)built.
library;

import 'dart:math' as math;
import 'dart:typed_data';

/// Pixel layout of a frame handed to [FrameSampler.fill].
abstract final class FrameFormat {
  /// Android camera: three planes (Y, U, V) with row/pixel strides.
  static const int yuv420 = 0;

  /// iOS camera: one interleaved BGRA plane.
  static const int bgra8888 = 1;

  /// Packed RGB, used for still images.
  static const int rgb = 2;
}

enum SamplerInputType { float32, int8, uint8 }

class FrameSampler {
  FrameSampler({
    required this.inputWidth,
    required this.inputHeight,
    required this.channelsFirst,
    required this.inputType,
    this.inputScale = 1.0,
    this.inputZeroPoint = 0,
    this.padValue = 114,
    this.boxFilterMinScale = 1.4,
  }) {
    if (inputWidth <= 0 || inputHeight <= 0) {
      throw ArgumentError('Model input must be at least 1×1');
    }
    final n = inputWidth * inputHeight * 3;
    switch (inputType) {
      case SamplerInputType.float32:
        final f = Float32List(n);
        _inF = f;
        inputBytes = Uint8List.view(f.buffer);
      case SamplerInputType.int8:
        final i = Int8List(n);
        _inI8 = i;
        inputBytes = Uint8List.view(i.buffer);
      case SamplerInputType.uint8:
        final u = Uint8List(n);
        _inU8 = u;
        inputBytes = u;
    }
    _xMapU = Int32List(inputWidth);
    _yMapU = Int32List(inputHeight);
    _colA = Int32List(inputWidth);
    _colB = Int32List(inputWidth);
    _buildLuts();
  }

  final int inputWidth;
  final int inputHeight;
  final bool channelsFirst;
  final SamplerInputType inputType;
  final double inputScale;
  final int inputZeroPoint;

  /// Letterbox grey (Ultralytics default).
  final int padValue;

  /// Enable the 2×2 luma box filter when the frame is downscaled at least
  /// this much (source pixels per model pixel).
  final double boxFilterMinScale;

  /// The model input tensor bytes. Same length as the tensor; hand it to
  /// `Tensor.data = ...` after [fill].
  late final Uint8List inputBytes;

  Float32List? _inF;
  Int8List? _inI8;
  Uint8List? _inU8;

  final Float32List _lutF = Float32List(256);
  final Int8List _lutI8 = Int8List(256);
  final Uint8List _lutU8 = Uint8List(256);

  // --- maps (rebuilt only when geometry changes) ---
  int _mapW = -1, _mapH = -1, _mapRot = -1, _mapFmt = -1;
  int _mapStride0 = -1, _mapUvStride = -1, _mapUvPix = -1;
  late final Int32List _xMapU;
  late final Int32List _yMapU;
  late final Int32List _colA;
  late final Int32List _colB;
  int _a0 = 0, _ay = 0, _b0 = 0, _by = 1;
  bool _rowIsY = true;
  int _maxSx = 0, _maxSy = 0, _bytesPerPixel = 1;
  bool _box2x2 = false;
  int _colStart = 0, _colEnd = 0, _rowStart = 0, _rowEnd = 0;
  int _padX = 0, _padY = 0, _contentW = 0, _contentH = 0;
  double _contentAspect = 1;

  // --- geometry of the last fill (normalised to the model input) ---
  double get padXNorm => _padX / inputWidth;
  double get padYNorm => _padY / inputHeight;
  double get contentWNorm => _contentW / inputWidth;
  double get contentHNorm => _contentH / inputHeight;
  int get padXPx => _padX;
  int get padYPx => _padY;
  int get contentWidthPx => _contentW;
  int get contentHeightPx => _contentH;

  /// Width / height of the upright frame.
  double get contentAspect => _contentAspect;
  bool get boxFilterActive => _box2x2;
  int get rotation => _mapRot < 0 ? 0 : _mapRot;

  static int normalizeRotation(int degrees) {
    final n = ((degrees % 360) + 360) % 360;
    return (n == 90 || n == 180 || n == 270) ? n : 0;
  }

  void _buildLuts() {
    final scale = inputScale == 0 ? 1.0 : inputScale;
    final q = 1.0 / (255.0 * scale);
    for (int v = 0; v < 256; v++) {
      _lutF[v] = v / 255.0;
      final qv = (v * q + inputZeroPoint).round();
      _lutI8[v] = qv.clamp(-128, 127);
      _lutU8[v] = qv.clamp(0, 255);
    }
  }

  /// Convert one frame into [inputBytes].
  ///
  /// [rowStride0] is bytes per row of [plane0] (Y plane, BGRA row or RGB
  /// row). [rowStride1]/[pixelStride1] describe the chroma planes (YUV only;
  /// `pixelStride1 == 2` is the common semi-planar layout).
  void fill({
    required int width,
    required int height,
    required int format,
    required Uint8List plane0,
    Uint8List? plane1,
    Uint8List? plane2,
    required int rowStride0,
    int rowStride1 = 0,
    int pixelStride1 = 1,
    required int rotation,
  }) {
    if (width <= 0 || height <= 0) throw ArgumentError('Empty frame');
    if (format == FrameFormat.yuv420 && (plane1 == null || plane2 == null)) {
      throw StateError('YUV420 frame without chroma planes');
    }
    final rot = normalizeRotation(rotation);
    _ensureMaps(width, height, rot, format, rowStride0, rowStride1,
        pixelStride1);

    final p0 = plane0;
    // Non-nullable locals so the inner loop has no null checks.
    final Uint8List p1 = plane1 ?? p0;
    final Uint8List p2 = plane2 ?? p0;
    final stride0 = rowStride0;
    final uvStride = rowStride1;
    final uvPix = pixelStride1;

    final colA = _colA;
    final colB = _colB;
    final a0 = _a0, ay = _ay, b0 = _b0, by = _by;
    final rowIsY = _rowIsY;
    final maxSx = _maxSx, maxSy = _maxSy;
    final bpp = _bytesPerPixel;
    final box = _box2x2;
    final isYuv = format == FrameFormat.yuv420;
    final isBgra = format == FrameFormat.bgra8888;

    final total = inputWidth * inputHeight;
    final cf = channelsFirst;
    final off1 = cf ? total : 1;
    final off2 = cf ? 2 * total : 2;
    final step = cf ? 1 : 3;

    final inF = _inF;
    final inI8 = _inI8;
    final Uint8List inU8 = _inU8 ?? Uint8List(0);
    final lutF = _lutF;
    final lutI8 = _lutI8;
    final lutU8 = _lutU8;
    final yMapU = _yMapU;

    for (int ty = _rowStart; ty < _rowEnd; ty++) {
      final uy = yMapU[ty];
      int rowA, rowB;
      if (rowIsY) {
        int sy = b0 + by * uy;
        sy = sy < 0 ? 0 : (sy > maxSy ? maxSy : sy);
        rowA = sy * stride0;
        rowB = (sy >> 1) * uvStride;
      } else {
        int sx = a0 + ay * uy;
        sx = sx < 0 ? 0 : (sx > maxSx ? maxSx : sx);
        rowA = sx * bpp;
        rowB = (sx >> 1) * uvPix;
      }
      final pix = ty * inputWidth + _colStart;
      int idx = cf ? pix : pix * 3;

      for (int tx = _colStart; tx < _colEnd; tx++, idx += step) {
        final s = rowA + colA[tx];
        int r, g, b;

        if (isYuv) {
          final int yp;
          if (box) {
            yp = (p0[s] +
                    p0[s + 1] +
                    p0[s + stride0] +
                    p0[s + stride0 + 1] +
                    2) >>
                2;
          } else {
            yp = p0[s];
          }
          final uvIdx = rowB + colB[tx];
          final u = p1[uvIdx] - 128;
          final v = p2[uvIdx] - 128;
          // BT.601 (full range), integer maths.
          r = yp + ((v * 1436) >> 10);
          g = yp - ((u * 352) >> 10) - ((v * 731) >> 10);
          b = yp + ((u * 1814) >> 10);
          r = r < 0 ? 0 : (r > 255 ? 255 : r);
          g = g < 0 ? 0 : (g > 255 ? 255 : g);
          b = b < 0 ? 0 : (b > 255 ? 255 : b);
        } else if (isBgra) {
          b = p0[s];
          g = p0[s + 1];
          r = p0[s + 2];
        } else {
          r = p0[s];
          g = p0[s + 1];
          b = p0[s + 2];
        }

        if (inF != null) {
          inF[idx] = lutF[r];
          inF[idx + off1] = lutF[g];
          inF[idx + off2] = lutF[b];
        } else if (inI8 != null) {
          inI8[idx] = lutI8[r];
          inI8[idx + off1] = lutI8[g];
          inI8[idx + off2] = lutI8[b];
        } else {
          inU8[idx] = lutU8[r];
          inU8[idx + off1] = lutU8[g];
          inU8[idx + off2] = lutU8[b];
        }
      }
    }
  }

  void _ensureMaps(
    int frameW,
    int frameH,
    int rot,
    int fmt,
    int stride0,
    int uvStride,
    int uvPix,
  ) {
    if (frameW == _mapW &&
        frameH == _mapH &&
        rot == _mapRot &&
        fmt == _mapFmt &&
        stride0 == _mapStride0 &&
        uvStride == _mapUvStride &&
        uvPix == _mapUvPix) {
      return;
    }

    final swap = rot == 90 || rot == 270;
    final upW = swap ? frameH : frameW;
    final upH = swap ? frameW : frameH;
    final scale = math.min(inputWidth / upW, inputHeight / upH);
    final contentW = (upW * scale).round().clamp(1, inputWidth);
    final contentH = (upH * scale).round().clamp(1, inputHeight);
    final padX = (inputWidth - contentW) ~/ 2;
    final padY = (inputHeight - contentH) ~/ 2;

    _box2x2 = fmt == FrameFormat.yuv420 &&
        (1.0 / scale) >= boxFilterMinScale &&
        frameW >= 2 &&
        frameH >= 2;
    final maxSx = _box2x2 ? frameW - 2 : frameW - 1;
    final maxSy = _box2x2 ? frameH - 2 : frameH - 1;
    _maxSx = maxSx;
    _maxSy = maxSy;
    _bytesPerPixel =
        fmt == FrameFormat.bgra8888 ? 4 : (fmt == FrameFormat.rgb ? 3 : 1);

    _colStart = -1;
    _colEnd = 0;
    for (int tx = 0; tx < inputWidth; tx++) {
      final ux = ((tx - padX) / scale).floor();
      if (ux < 0 || ux >= upW) {
        _xMapU[tx] = -1;
      } else {
        _xMapU[tx] = ux;
        if (_colStart < 0) _colStart = tx;
        _colEnd = tx + 1;
      }
    }
    _rowStart = -1;
    _rowEnd = 0;
    for (int ty = 0; ty < inputHeight; ty++) {
      final uy = ((ty - padY) / scale).floor();
      if (uy < 0 || uy >= upH) {
        _yMapU[ty] = -1;
      } else {
        _yMapU[ty] = uy;
        if (_rowStart < 0) _rowStart = ty;
        _rowEnd = ty + 1;
      }
    }
    if (_colStart < 0) _colStart = 0;
    if (_rowStart < 0) _rowStart = 0;

    // Source (sx, sy) of upright (ux, uy) for a clockwise rotation of the
    // raw frame by `rot` degrees:
    //   sx = a0 + ax*ux + ay*uy
    //   sy = b0 + bx*ux + by*uy
    int ax, ay, bx, by, a0, b0;
    switch (rot) {
      case 90:
        ax = 0; ay = 1; a0 = 0;
        bx = -1; by = 0; b0 = frameH - 1;
      case 180:
        ax = -1; ay = 0; a0 = frameW - 1;
        bx = 0; by = -1; b0 = frameH - 1;
      case 270:
        ax = 0; ay = -1; a0 = frameW - 1;
        bx = 1; by = 0; b0 = 0;
      default:
        ax = 1; ay = 0; a0 = 0;
        bx = 0; by = 1; b0 = 0;
    }
    _a0 = a0;
    _ay = ay;
    _b0 = b0;
    _by = by;
    // Rotation 0/180: sx varies per column, sy per row. 90/270: the reverse.
    _rowIsY = rot == 0 || rot == 180;
    final bpp = _bytesPerPixel;
    for (int tx = 0; tx < inputWidth; tx++) {
      final ux = _xMapU[tx];
      if (ux < 0) {
        _colA[tx] = 0;
        _colB[tx] = 0;
        continue;
      }
      if (_rowIsY) {
        int sx = a0 + ax * ux;
        sx = sx < 0 ? 0 : (sx > maxSx ? maxSx : sx);
        _colA[tx] = sx * bpp;
        _colB[tx] = (sx >> 1) * uvPix;
      } else {
        int sy = b0 + bx * ux;
        sy = sy < 0 ? 0 : (sy > maxSy ? maxSy : sy);
        _colA[tx] = sy * stride0;
        _colB[tx] = (sy >> 1) * uvStride;
      }
    }

    _padX = padX;
    _padY = padY;
    _contentW = contentW;
    _contentH = contentH;
    _contentAspect = upW / upH;

    _fillPad();

    _mapW = frameW;
    _mapH = frameH;
    _mapRot = rot;
    _mapFmt = fmt;
    _mapStride0 = stride0;
    _mapUvStride = uvStride;
    _mapUvPix = uvPix;
  }

  void _fillPad() {
    final pad = padValue.clamp(0, 255);
    final f = _inF;
    if (f != null) {
      f.fillRange(0, f.length, _lutF[pad]);
      return;
    }
    final i8 = _inI8;
    if (i8 != null) {
      i8.fillRange(0, i8.length, _lutI8[pad]);
      return;
    }
    final u8 = _inU8!;
    u8.fillRange(0, u8.length, _lutU8[pad]);
  }

  /// Debug / test helper: the current input decoded back to packed RGB
  /// (`inputWidth × inputHeight × 3`), whatever the layout and dtype.
  Uint8List toRgb() {
    final n = inputWidth * inputHeight;
    final out = Uint8List(n * 3);
    for (int p = 0; p < n; p++) {
      for (int c = 0; c < 3; c++) {
        final idx = channelsFirst ? c * n + p : p * 3 + c;
        out[p * 3 + c] = _decode(idx);
      }
    }
    return out;
  }

  int _decode(int idx) {
    final f = _inF;
    if (f != null) return (f[idx] * 255.0).round().clamp(0, 255);
    final scale = inputScale == 0 ? 1.0 : inputScale;
    final i8 = _inI8;
    if (i8 != null) {
      return ((i8[idx] - inputZeroPoint) * scale * 255.0).round().clamp(0, 255);
    }
    return ((_inU8![idx] - inputZeroPoint) * scale * 255.0)
        .round()
        .clamp(0, 255);
  }
}
