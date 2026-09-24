// Pure Dart: `dart test test/frame_sampler_test.dart`.
//
// Verifies the model-input geometry that would otherwise fail silently:
// letterbox placement, all four rotations, the 2×2 box filter, chroma
// conversion, planar vs semi-planar chroma, BGRA order, NCHW layout and int8
// quantisation.
import 'dart:typed_data';

import 'package:tareeqi/services/frame_sampler.dart';
import 'package:test/test.dart';

class YuvFrame {
  YuvFrame(this.w, this.h, this.y, this.u, this.v, this.yStride, this.uvStride,
      this.uvPix);
  final int w, h;
  final Uint8List y, u, v;
  final int yStride, uvStride, uvPix;
}

/// Planar I420-style frame with per-pixel luma and per-chroma-sample values.
YuvFrame planar(
  int w,
  int h,
  int Function(int x, int y) yAt, {
  int Function(int cx, int cy)? uAt,
  int Function(int cx, int cy)? vAt,
}) {
  final y = Uint8List(w * h);
  for (int yy = 0; yy < h; yy++) {
    for (int x = 0; x < w; x++) {
      y[yy * w + x] = yAt(x, yy);
    }
  }
  final cw = w ~/ 2, ch = h ~/ 2;
  final u = Uint8List(cw * ch), v = Uint8List(cw * ch);
  for (int cy = 0; cy < ch; cy++) {
    for (int cx = 0; cx < cw; cx++) {
      u[cy * cw + cx] = uAt?.call(cx, cy) ?? 128;
      v[cy * cw + cx] = vAt?.call(cx, cy) ?? 128;
    }
  }
  return YuvFrame(w, h, y, u, v, w, cw, 1);
}

/// Semi-planar (NV12-like, as camerax delivers): one interleaved UV buffer,
/// plane1 = view at offset 0, plane2 = view at offset 1, pixel stride 2.
YuvFrame semiPlanar(YuvFrame src) {
  final cw = src.w ~/ 2, ch = src.h ~/ 2;
  final uv = Uint8List(cw * ch * 2);
  for (int i = 0; i < cw * ch; i++) {
    uv[2 * i] = src.u[i];
    uv[2 * i + 1] = src.v[i];
  }
  return YuvFrame(
    src.w,
    src.h,
    src.y,
    Uint8List.sublistView(uv, 0),
    Uint8List.sublistView(uv, 1),
    src.yStride,
    cw * 2,
    2,
  );
}

FrameSampler sampler({
  int size = 8,
  bool nchw = false,
  SamplerInputType type = SamplerInputType.float32,
  double scale = 1.0,
  int zeroPoint = 0,
}) =>
    FrameSampler(
      inputWidth: size,
      inputHeight: size,
      channelsFirst: nchw,
      inputType: type,
      inputScale: scale,
      inputZeroPoint: zeroPoint,
    );

void fillYuv(FrameSampler s, YuvFrame f, int rotation) => s.fill(
      width: f.w,
      height: f.h,
      format: FrameFormat.yuv420,
      plane0: f.y,
      plane1: f.u,
      plane2: f.v,
      rowStride0: f.yStride,
      rowStride1: f.uvStride,
      pixelStride1: f.uvPix,
      rotation: rotation,
    );

(int, int, int) px(Uint8List rgb, int w, int x, int y) {
  final i = (y * w + x) * 3;
  return (rgb[i], rgb[i + 1], rgb[i + 2]);
}

void main() {
  // 8×4 landscape frame, grey (U=V=128 → r=g=b=Y), unique Y per pixel.
  int lum(int x, int y) => 10 + 20 * x + 5 * y;

  group('letterbox', () {
    test('rotation 0: 8×4 frame centred in 8×8 input, grey 114 padding', () {
      final s = sampler();
      fillYuv(s, planar(8, 4, lum), 0);
      expect(s.boxFilterActive, isFalse);
      expect(s.padXPx, 0);
      expect(s.padYPx, 2);
      expect(s.contentWidthPx, 8);
      expect(s.contentHeightPx, 4);
      expect(s.contentAspect, 2.0);

      final rgb = s.toRgb();
      for (int y = 0; y < 8; y++) {
        for (int x = 0; x < 8; x++) {
          final (r, g, b) = px(rgb, 8, x, y);
          if (y < 2 || y >= 6) {
            expect((r, g, b), (114, 114, 114), reason: 'pad at ($x,$y)');
          } else {
            final expected = lum(x, y - 2);
            expect(r, expected, reason: 'content at ($x,$y)');
            expect(g, expected);
            expect(b, expected);
          }
        }
      }
    });
  });

  group('rotation (clockwise, raw sensor frame → upright)', () {
    // Upright (ux, uy) ← source (sx, sy):
    //  90:  sx = uy,        sy = H-1-ux
    //  180: sx = W-1-ux,    sy = H-1-uy
    //  270: sx = W-1-uy,    sy = ux
    test('90: upright is 4 wide × 8 tall, padded left/right', () {
      final s = sampler();
      fillYuv(s, planar(8, 4, lum), 90);
      expect(s.padXPx, 2);
      expect(s.padYPx, 0);
      expect(s.contentAspect, 0.5);
      final rgb = s.toRgb();
      for (int uy = 0; uy < 8; uy++) {
        for (int ux = 0; ux < 4; ux++) {
          final (r, _, _) = px(rgb, 8, 2 + ux, uy);
          expect(r, lum(uy, 3 - ux), reason: 'upright ($ux,$uy)');
        }
        expect(px(rgb, 8, 0, uy).$1, 114);
        expect(px(rgb, 8, 7, uy).$1, 114);
      }
    });

    test('180', () {
      final s = sampler();
      fillYuv(s, planar(8, 4, lum), 180);
      final rgb = s.toRgb();
      for (int uy = 0; uy < 4; uy++) {
        for (int ux = 0; ux < 8; ux++) {
          expect(px(rgb, 8, ux, 2 + uy).$1, lum(7 - ux, 3 - uy));
        }
      }
    });

    test('270', () {
      final s = sampler();
      fillYuv(s, planar(8, 4, lum), 270);
      final rgb = s.toRgb();
      for (int uy = 0; uy < 8; uy++) {
        for (int ux = 0; ux < 4; ux++) {
          expect(px(rgb, 8, 2 + ux, uy).$1, lum(7 - uy, ux));
        }
      }
    });

    test('rotation change rebuilds maps and pad in place', () {
      final s = sampler();
      fillYuv(s, planar(8, 4, lum), 0);
      fillYuv(s, planar(8, 4, lum), 90);
      final rgb = s.toRgb();
      // Column 0 was content at rotation 0, must be pad at rotation 90.
      expect(px(rgb, 8, 0, 4).$1, 114);
      expect(s.rotation, 90);
    });
  });

  group('2×2 box filter', () {
    test('active when downscaling 2×, averages 2×2 luma', () {
      final s = sampler();
      // 16×8 → 8×8 input: scale 0.5, content 8×4 at rows 2..5.
      fillYuv(s, planar(16, 8, (x, y) => 10 * x), 0);
      expect(s.boxFilterActive, isTrue);
      final rgb = s.toRgb();
      for (int ty = 0; ty < 4; ty++) {
        for (int tx = 0; tx < 8; tx++) {
          // Y at columns 2tx and 2tx+1 → 20tx and 20tx+10 → mean 20tx+5.
          expect(px(rgb, 8, tx, 2 + ty).$1, 20 * tx + 5,
              reason: 'box mean at ($tx,$ty)');
        }
      }
    });

    test('inactive below the threshold (1.125×)', () {
      final s = sampler(size: 16);
      fillYuv(s, planar(18, 9, (x, y) => x), 0);
      expect(s.boxFilterActive, isFalse);
    });
  });

  group('colour', () {
    test('BT.601 chroma conversion is within ±2 of the float reference', () {
      final s = sampler();
      fillYuv(s, planar(8, 4, (x, y) => 100, uAt: (_, _) => 90, vAt: (_, _) => 200), 0);
      final (r, g, b) = px(s.toRgb(), 8, 3, 3);
      // R = Y + 1.402 (V-128); G = Y - 0.344 (U-128) - 0.714 (V-128);
      // B = Y + 1.772 (U-128)
      expect((r - 200.9).abs(), lessThanOrEqualTo(2));
      expect((g - 61.7).abs(), lessThanOrEqualTo(2));
      expect((b - 32.7).abs(), lessThanOrEqualTo(2));
    });

    test('semi-planar chroma (pixel stride 2) matches planar', () {
      final src = planar(
        8,
        4,
        (x, y) => 120,
        uAt: (cx, _) => cx < 2 ? 90 : 128,
        vAt: (cx, _) => cx < 2 ? 200 : 128,
      );
      final a = sampler();
      final b = sampler();
      fillYuv(a, src, 0);
      fillYuv(b, semiPlanar(src), 0);
      expect(b.toRgb(), a.toRgb());
      // Left half is tinted, right half is grey.
      expect(px(b.toRgb(), 8, 1, 3).$1, isNot(120));
      expect(px(b.toRgb(), 8, 6, 3), (120, 120, 120));
    });

    test('BGRA input keeps channel order', () {
      final s = sampler();
      final bgra = Uint8List(8 * 4 * 4);
      for (int i = 0; i < 8 * 4; i++) {
        bgra[i * 4] = 10; // B
        bgra[i * 4 + 1] = 20; // G
        bgra[i * 4 + 2] = 30; // R
        bgra[i * 4 + 3] = 255;
      }
      s.fill(
        width: 8,
        height: 4,
        format: FrameFormat.bgra8888,
        plane0: bgra,
        rowStride0: 8 * 4,
        rotation: 0,
      );
      expect(px(s.toRgb(), 8, 4, 3), (30, 20, 10));
    });
  });

  group('layout and dtype', () {
    test('NCHW float: channel planes are contiguous', () {
      final s = sampler(nchw: true);
      fillYuv(s, planar(8, 4, (x, y) => 200, uAt: (_, _) => 90, vAt: (_, _) => 200), 0);
      final f = Float32List.view(s.inputBytes.buffer);
      const n = 64;
      final p = 3 * 8 + 4; // some content pixel
      final rgb = s.toRgb();
      final (r, g, b) = px(rgb, 8, 4, 3);
      expect((f[p] * 255).round(), r);
      expect((f[n + p] * 255).round(), g);
      expect((f[2 * n + p] * 255).round(), b);
      // toRgb must agree with an NHWC sampler on the same frame.
      final nhwc = sampler();
      fillYuv(nhwc, planar(8, 4, (x, y) => 200, uAt: (_, _) => 90, vAt: (_, _) => 200), 0);
      expect(rgb, nhwc.toRgb());
    });

    test('int8 quantisation: q = round(v/255/scale) + zeroPoint', () {
      // scale 1/255, zp -128 → q = v - 128 (the usual full-int8 export).
      final s = sampler(type: SamplerInputType.int8, scale: 1 / 255, zeroPoint: -128);
      fillYuv(s, planar(8, 4, lum), 0);
      final q = Int8List.view(s.inputBytes.buffer);
      // Pad pixel (row 0) → 114 - 128 = -14.
      expect(q[0], -14);
      // Content pixel (x=3, row 2 ↔ source y 0): lum(3,0) = 70 → -58.
      expect(q[(2 * 8 + 3) * 3], 70 - 128);
      expect(s.inputBytes.length, 8 * 8 * 3);
    });

    test('inputBytes length matches the tensor for every dtype', () {
      expect(sampler().inputBytes.length, 8 * 8 * 3 * 4);
      expect(sampler(type: SamplerInputType.int8).inputBytes.length, 8 * 8 * 3);
      expect(sampler(type: SamplerInputType.uint8).inputBytes.length, 8 * 8 * 3);
    });
  });
}
