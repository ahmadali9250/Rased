import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:tflite_flutter/tflite_flutter.dart';

/// ============================================================================
/// ثوابت GPU delegate — قيم رقمية من TensorFlow Lite C API الرسمي.
///
/// ملاحظة مهمة: مكتبة tflite_flutter تعرّف هاي القيم داخلياً بملف
/// `src/bindings/tensorflow_lite_bindings_generated.dart` وهو **غير مُصدَّر**
/// من المكتبة العامة. استيراده مباشرة يعطي تحذير `implementation_imports`
/// وممكن ينكسر بأي تحديث للمكتبة.
///
/// الحل: نمرر الأرقام مباشرة — الـ factory أصلاً بيستقبل `int` وليس enum،
/// وهاي الأرقام جزء من الـ C API نفسه (delegates/gpu/delegate_options.h)
/// فما بتتغير بين إصدارات الـ Dart binding.
/// ============================================================================

// TfLiteGpuInferenceUsage
const int _kGpuUsageFastSingleAnswer = 0; // فريم واحد بكل استدعاء (حالتنا بالضبط)
// ignore: unused_element
const int _kGpuUsageSustainedSpeed = 1; // throughput مستمر (batch) — مش حالتنا

// TfLiteGpuInferencePriority
const int _kGpuPriorityAuto = 0;
// ignore: unused_element
const int _kGpuPriorityMaxPrecision = 1;
const int _kGpuPriorityMinLatency = 2; // ⚡ هدفنا الأول: أقل زمن استجابة
// ignore: unused_element
const int _kGpuPriorityMinMemoryUsage = 3;

/// خدمة الاستنتاج المحلي (YOLO26n / best_w8a32.tflite).
///
/// تحسينات الأداء المطبّقة:
///  1. GPU delegate بأولوية MIN_LATENCY (بدل MAX_PRECISION الافتراضي).
///  2. **Isolate دائم** — يُنشأ مرة واحدة فقط بدل `compute()` اللي بيولّد
///     isolate جديد كل فريم (تكلفة إنشاء/إنهاء الـ isolate كانت أغلى من
///     الاستنتاج نفسه أحياناً).
///  3. **Back-pressure**: أي فريم يوصل والـ worker مشغول بينرمي فوراً،
///     فما بيتراكم طابور فريمات ويصير التطبيق "متأخر عن الواقع".
///  4. **Frame skipping**: تحليل فريم من كل N (افتراضياً 1 من 3).
///  5. **إعادة استخدام كل الـ buffers** (input + output) بدل تخصيص جديد كل فريم.
///  6. **جداول بحث مسبقة** لإحداثيات العيّنة (sx/sy) — بتلغي قسمة integer
///     لكل بكسل داخل اللوب المتداخل.
///  7. تحويل YUV→RGB + تصغير بمرور واحد على أبعاد الموديل مباشرة.
class TFLiteService {
  // --- الموديل ---
  Interpreter? _interpreter;
  List<String>? _labels;

  int _inputWidth = 0;
  int _inputHeight = 0;
  TensorType _inputType = TensorType.float32;
  double _inputScale = 1.0;
  int _inputZeroPoint = 0;

  // --- الـ isolate الدائم ---
  Isolate? _isolate;
  SendPort? _workerPort;
  ReceivePort? _fromWorker;
  Completer<Map<String, dynamic>>? _pending;
  bool _workerReady = false;

  // --- تنظيم معدل الفريمات ---
  int _frameCounter = 0;

  /// حلّل فريم واحد من كل (N).
  ///
  /// ⚠️ خليها = 1 إذا الشاشة أصلاً بتنظّم المعدل بالوقت (مثل LiveCameraScreen
  /// اللي بتستخدم `_fpsIntervalMs`)، وإلا التنظيمين بيتراكمو وبيصير المعدل
  /// الفعلي أبطأ بكثير من المقصود (مثلاً 8 FPS ÷ 3 = ~2.7 تحليل/ثانية).
  static const int frameSkipRate = 1;

  // تبدأ هذه القيمة منخفضة عمداً أثناء الاختبار الميداني. تأكيد ثلاثة
  // فريمات في الشاشة يمنع البلاغات العابرة، بينما تسجيل أعلى score يجعل
  // ضبط العتبة لاحقاً مبنياً على صور الهاتف لا على بيانات التدريب فقط.
  static const double _confThreshold = 0.20;
  static const double _iouThreshold = 0.45;
  static const String _modelAsset = 'assets/best_w8a32.tflite';

  bool get isReady => _interpreter != null && _workerReady;

  // ==========================================================================
  // التهيئة
  // ==========================================================================

  Future<void> initializeModel() async {
    if (_interpreter != null) return; // تهيئة مرة وحدة بس

    _interpreter = await _loadInterpreterWithBestDelegate();
    if (_interpreter == null) {
      debugPrint('❌ فشل تحميل الموديل نهائياً (GPU وNNAPI وCPU كلهم فشلوا)');
      return;
    }

    final labelFile = await rootBundle.loadString('assets/classes.txt');
    _labels = labelFile
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toList();

    final inputTensor = _interpreter!.getInputTensor(0);
    final inputShape = inputTensor.shape;
    _inputHeight = inputShape[1];
    _inputWidth = inputShape[2];
    _inputType = inputTensor.type;
    _inputScale = inputTensor.params.scale;
    _inputZeroPoint = inputTensor.params.zeroPoint;
    final outputTensor = _interpreter!.getOutputTensor(0);

    debugPrint(
      '✅ الموديل جاهز | input: ${_inputWidth}x$_inputHeight '
      '| type: $_inputType | q=($_inputScale, $_inputZeroPoint) '
      '| output: ${outputTensor.shape} ${outputTensor.type} '
      'q=(${outputTensor.params.scale}, ${outputTensor.params.zeroPoint}) '
      '| labels: $_labels',
    );

    await _startWorkerIsolate();
  }

  /// ترتيب المحاولات: GPU (min latency) → NNAPI → CPU متعدد الخيوط.
  Future<Interpreter?> _loadInterpreterWithBestDelegate() async {
    // 1) GPU delegate — الأسرع بفارق كبير (بنشمارك: ~4.7ms مقابل ~29ms على CPU)
    try {
      final gpuDelegate = GpuDelegateV2(
        options: GpuDelegateOptionsV2(
          // يسمح للـ GPU يشتغل FP16 / يكمّم داخلياً. الموديل أصلاً w8a32
          // فالفقدان بالدقة مهمل عملياً، والمكسب بالسرعة كبير.
          isPrecisionLossAllowed: true,
          inferencePreference: _kGpuUsageFastSingleAnswer,
          // ⚡ الافتراضي هو MAX_PRECISION — نحن بدنا العكس تماماً.
          inferencePriority1: _kGpuPriorityMinLatency,
          inferencePriority2: _kGpuPriorityAuto,
          inferencePriority3: _kGpuPriorityAuto,
          // ENABLE_QUANT مفعّل افتراضياً وهو ضروري لموديل w8a32 (تنسورات مكمّمة).
          maxDelegatePartitions: 1,
        ),
      );
      final options = InterpreterOptions()..addDelegate(gpuDelegate);
      final interpreter =
          await Interpreter.fromAsset(_modelAsset, options: options);
      debugPrint('✅ GPU delegate اشتغل (أولوية: أقل زمن استجابة)');
      return interpreter;
    } catch (e) {
      debugPrint('⚠️ GPU delegate فشل ($e) — جرّب NNAPI...');
    }

    // 2) NNAPI — بيستغل أي مسرّع بالشريحة (NPU/DSP/GPU)
    try {
      final options = InterpreterOptions()..useNnApiForAndroid = true;
      final interpreter =
          await Interpreter.fromAsset(_modelAsset, options: options);
      debugPrint('✅ NNAPI delegate اشتغل');
      return interpreter;
    } catch (e) {
      debugPrint('⚠️ NNAPI فشل ($e) — رجوع لـ CPU...');
    }

    // 3) CPU (XNNPACK) — آخر حل، بعدد خيوط = أنوية الجهاز (بحد أقصى 4)
    try {
      final cores = Platform.numberOfProcessors;
      final threads = cores > 4 ? 4 : (cores < 1 ? 1 : cores);
      final options = InterpreterOptions()..threads = threads;
      debugPrint('ℹ️ CPU fallback بـ $threads خيوط');
      return await Interpreter.fromAsset(_modelAsset, options: options);
    } catch (e) {
      debugPrint('❌ حتى CPU فشل: $e');
      return null;
    }
  }

  /// يُنشئ الـ isolate الدائم ويسلّمه عنوان الـ interpreter + أبعاد الإدخال.
  Future<void> _startWorkerIsolate() async {
    _fromWorker = ReceivePort();

    _isolate = await Isolate.spawn(
      _workerEntry,
      _WorkerInit(
        mainPort: _fromWorker!.sendPort,
        interpreterAddress: _interpreter!.address,
        inputWidth: _inputWidth,
        inputHeight: _inputHeight,
        inputTypeIndex: _inputType.index,
        inputScale: _inputScale,
        inputZeroPoint: _inputZeroPoint,
        labels: _labels!,
        confThreshold: _confThreshold,
        iouThreshold: _iouThreshold,
      ),
      debugName: 'rased_tflite_worker',
    );

    final ready = Completer<void>();

    _fromWorker!.listen((message) {
      if (message is SendPort) {
        _workerPort = message;
        _workerReady = true;
        if (!ready.isCompleted) ready.complete();
        debugPrint('✅ isolate الاستنتاج الدائم جاهز');
      } else if (message is Map<String, dynamic>) {
        final error = message['error'];
        if (error != null) {
          debugPrint('❌ فشل worker الاستنتاج: $error');
        }
        final p = _pending;
        _pending = null;
        if (p != null && !p.isCompleted) p.complete(message);
      }
    });

    await ready.future;
  }

  void dispose() {
    _workerPort?.send('close');
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    _fromWorker?.close();
    _fromWorker = null;
    _workerPort = null;
    _workerReady = false;
    _pending = null;
    _interpreter?.close();
    _interpreter = null;
  }

  // ==========================================================================
  // DASHCAM MODE — فريم كاميرا حي
  // ==========================================================================

  /// يرجّع `{'label': String, 'detections': List<Map>}` عند التحليل الفعلي.
  ///
  /// ⚠️ يرجّع **null** (مش نتيجة فاضية) إذا:
  ///  - الفريم ضمن الفريمات المتخطّاة (frame skipping)، أو
  ///  - الـ worker لسا مشغول بفريم سابق (back-pressure).
  ///
  /// التمييز بين null و'Clear Road' حرج: بدونه الفريم المتخطّى بينقرأ كأنه
  /// "طريق نظيف" فبيمسح المربعات من الشاشة ويصفّر عدّاد التأكيد الزمني.
  Future<Map<String, dynamic>?> predictFrameWithBoxes(
      CameraImage cameraImage) async {
    if (!isReady) return null;

    // 1) تخطي فريمات
    _frameCounter++;
    if (frameSkipRate > 1 && _frameCounter % frameSkipRate != 0) return null;

    // 2) رمي الفريم لو الـ worker مشغول (لا طابور، لا تأخير تراكمي)
    if (_pending != null) return null;

    try {
      final completer = Completer<Map<String, dynamic>>();
      _pending = completer;

      _workerPort!.send(_FramePayload(
        isYuv: cameraImage.format.group == ImageFormatGroup.yuv420,
        width: cameraImage.width,
        height: cameraImage.height,
        plane0: cameraImage.planes[0].bytes,
        plane1:
            cameraImage.planes.length > 1 ? cameraImage.planes[1].bytes : null,
        plane2:
            cameraImage.planes.length > 2 ? cameraImage.planes[2].bytes : null,
        yRowStride: cameraImage.planes[0].bytesPerRow,
        uvRowStride:
            cameraImage.planes.length > 1 ? cameraImage.planes[1].bytesPerRow : 0,
        uvPixelStride: cameraImage.planes.length > 1
            ? (cameraImage.planes[1].bytesPerPixel ?? 1)
            : 1,
      ));

      // حماية من التعليق لو صار خطأ غير متوقع جوا الـ worker
      return await completer.future.timeout(
        const Duration(seconds: 2),
        onTimeout: () {
          _pending = null;
          debugPrint('⚠️ انتهت مهلة الفريم — تم تجاهله');
          return _empty;
        },
      );
    } catch (e) {
      _pending = null;
      debugPrint('❌ خطأ بإرسال الفريم: $e');
      return null;
    }
  }

  /// توافق خلفي مع أي كود قديم بيتوقع String بس.
  Future<String> predictFrame(CameraImage cameraImage) async {
    final result = await predictFrameWithBoxes(cameraImage);
    return result?['label'] as String? ?? 'Clear Road';
  }

  // ==========================================================================
  // MANUAL MODE — صورة ثابتة (استدعاء واحد، مش لايف)
  // ==========================================================================

  /// يرجّع `{'label': String, 'detections': List<Map>}`.
  ///
  /// ⚠️ تنبيه: يرجّع Map مش String (تغيّر عن النسخة القديمة).
  /// الاستخدام الصحيح: `final r = await predictImage(path); r['label'] as String`
  Future<Map<String, dynamic>> predictImage(String imagePath) async {
    if (_interpreter == null || _labels == null) return _empty;
    try {
      final bytes = await File(imagePath).readAsBytes();
      final decoded = img.decodeImage(bytes);
      if (decoded == null) return _empty;

      // نفس letterbox المستخدم في مسار الكاميرا وتدريب YOLO: لا نمدّ
      // الحفرة أفقياً/عمودياً إلى مربع لأن ذلك يغيّر شكلها وثقتها.
      final scale = (_inputWidth / decoded.width) < (_inputHeight / decoded.height)
          ? (_inputWidth / decoded.width)
          : (_inputHeight / decoded.height);
      final resizedW = (decoded.width * scale).round();
      final resizedH = (decoded.height * scale).round();
      final source = img.copyResize(
        decoded,
        width: resizedW,
        height: resizedH,
        interpolation: img.Interpolation.linear,
      );
      final padX = (_inputWidth - resizedW) ~/ 2;
      final padY = (_inputHeight - resizedH) ~/ 2;

      final totalPixels = _inputWidth * _inputHeight;
      final TypedData buffer;

      if (_inputType == TensorType.float32) {
        final f = Float32List(totalPixels * 3);
        int i = 0;
        for (int y = 0; y < _inputHeight; y++) {
          for (int x = 0; x < _inputWidth; x++) {
            final inImage = x >= padX && x < padX + resizedW && y >= padY && y < padY + resizedH;
            final p = inImage ? source.getPixel(x - padX, y - padY) : null;
            f[i++] = (p?.r ?? 114) / 255.0;
            f[i++] = (p?.g ?? 114) / 255.0;
            f[i++] = (p?.b ?? 114) / 255.0;
          }
        }
        buffer = f;
      } else {
        final u = Uint8List(totalPixels * 3);
        final scale = _inputScale == 0 ? 1.0 : _inputScale;
        int i = 0;
        for (int y = 0; y < _inputHeight; y++) {
          for (int x = 0; x < _inputWidth; x++) {
            final inImage = x >= padX && x < padX + resizedW && y >= padY && y < padY + resizedH;
            final p = inImage ? source.getPixel(x - padX, y - padY) : null;
            u[i++] =
                (((p?.r ?? 114) / 255.0) / scale + _inputZeroPoint).round().clamp(0, 255);
            u[i++] =
                (((p?.g ?? 114) / 255.0) / scale + _inputZeroPoint).round().clamp(0, 255);
            u[i++] =
                (((p?.b ?? 114) / 255.0) / scale + _inputZeroPoint).round().clamp(0, 255);
          }
        }
        buffer = u;
      }

      return _runInference(
        interpreter: _interpreter!,
        inputBuffer: buffer,
        labels: _labels!,
        confThreshold: _confThreshold,
        iouThreshold: _iouThreshold,
        cache: null,
      );
    } catch (e) {
      debugPrint('❌ خطأ بتحليل الصورة: $e');
      return _empty;
    }
  }

  static Map<String, dynamic> get _empty =>
      {'label': 'Clear Road', 'detections': const <Map<String, dynamic>>[]};

  // ==========================================================================
  // الـ WORKER ISOLATE
  // ==========================================================================

  static void _workerEntry(_WorkerInit init) {
    final rp = ReceivePort();
    init.mainPort.send(rp.sendPort);

    final interpreter = Interpreter.fromAddress(init.interpreterAddress);
    final inputType = TensorType.values[init.inputTypeIndex];
    final w = init.inputWidth;
    final h = init.inputHeight;
    final totalPixels = w * h;

    // ── تخصيص مرة واحدة فقط (بدل كل فريم) ────────────────────────────────
    final Float32List? floatBuf =
        inputType == TensorType.float32 ? Float32List(totalPixels * 3) : null;
    final Uint8List? uint8Buf =
        inputType != TensorType.float32 ? Uint8List(totalPixels * 3) : null;

    // جداول بحث للإحداثيات: بتلغي عمليتي قسمة integer لكل بكسل داخل اللوب.
    final xMap = Int32List(w);
    final yMap = Int32List(h);

    final cache = _OutputCache(interpreter);

    int lastSrcW = -1, lastSrcH = -1;

    rp.listen((message) {
      if (message == 'close') {
        rp.close();
        return;
      }
      if (message is! _FramePayload) return;

      try {
        final f = message;

        // Letterbox مطابق لـ YOLO: احتفظ بنسبة الأبعاد واملأ الحواف بـ114.
        // القيمة -1 في الخريطة تعني padding وليست بكسلاً من الكاميرا.
        if (f.width != lastSrcW || f.height != lastSrcH) {
          final resizeScale = (w / f.width) < (h / f.height)
              ? (w / f.width)
              : (h / f.height);
          final resizedW = (f.width * resizeScale).round();
          final resizedH = (f.height * resizeScale).round();
          final padX = (w - resizedW) ~/ 2;
          final padY = (h - resizedH) ~/ 2;
          for (int tx = 0; tx < w; tx++) {
            final v = ((tx - padX) / resizeScale).floor();
            xMap[tx] = v < 0 || v >= f.width ? -1 : v;
          }
          for (int ty = 0; ty < h; ty++) {
            final v = ((ty - padY) / resizeScale).floor();
            yMap[ty] = v < 0 || v >= f.height ? -1 : v;
          }
          lastSrcW = f.width;
          lastSrcH = f.height;
        }

        _fillInputBuffer(
          frame: f,
          inputWidth: w,
          inputHeight: h,
          xMap: xMap,
          yMap: yMap,
          floatBuf: floatBuf,
          uint8Buf: uint8Buf,
          inputScale: init.inputScale,
          inputZeroPoint: init.inputZeroPoint,
        );

        final result = _runInference(
          interpreter: interpreter,
          inputBuffer: (floatBuf ?? uint8Buf)!,
          labels: init.labels,
          confThreshold: init.confThreshold,
          iouThreshold: init.iouThreshold,
          cache: cache,
        );

        init.mainPort.send(result);
      } catch (e, stack) {
        init.mainPort.send({
          'label': 'Clear Road',
          'detections': <Map<String, dynamic>>[],
          'error': '$e\n$stack',
        });
      }
    });
  }

  /// يعبّي الـ buffer الجاهز مباشرة من بيانات الكاميرا الخام.
  /// تحويل اللون + التصغير بمرور واحد، بدون أي تخصيص ذاكرة جديد.
  static void _fillInputBuffer({
    required _FramePayload frame,
    required int inputWidth,
    required int inputHeight,
    required Int32List xMap,
    required Int32List yMap,
    required Float32List? floatBuf,
    required Uint8List? uint8Buf,
    required double inputScale,
    required int inputZeroPoint,
  }) {
    final bool isFloat = floatBuf != null;
    final double scale = inputScale == 0 ? 1.0 : inputScale;
    // للتكميم: نحسب المعامل مرة وحدة برا اللوب بدل قسمة لكل قناة لكل بكسل.
    final double qFactor = 1.0 / (255.0 * scale);

    int dst = 0;

    if (frame.isYuv) {
      final p0 = frame.plane0;
      final p1 = frame.plane1;
      final p2 = frame.plane2;
      if (p1 == null || p2 == null) throw Exception('YUV420 بدون chroma planes');

      final yStride = frame.yRowStride;
      final uvStride = frame.uvRowStride;
      final uvPixel = frame.uvPixelStride;

      for (int ty = 0; ty < inputHeight; ty++) {
        final sy = yMap[ty];
        final yRow = sy < 0 ? 0 : sy * yStride;
        final uvRow = sy < 0 ? 0 : (sy >> 1) * uvStride;

        for (int tx = 0; tx < inputWidth; tx++) {
          final sx = xMap[tx];
          int r = 114, g = 114, b = 114;
          if (sx >= 0 && sy >= 0) {
            final uvIdx = uvPixel * (sx >> 1) + uvRow;
            final yp = p0[yRow + sx];
            final up = p1[uvIdx];
            final vp = p2[uvIdx];

            // BT.601 بحساب صحيح (integer) — أسرع من الكسور العشرية
            r = yp + ((vp - 128) * 1436 >> 10);
            g = yp - ((up - 128) * 352 >> 10) - ((vp - 128) * 731 >> 10);
            b = yp + ((up - 128) * 1814 >> 10);
          }

          r = r < 0 ? 0 : (r > 255 ? 255 : r);
          g = g < 0 ? 0 : (g > 255 ? 255 : g);
          b = b < 0 ? 0 : (b > 255 ? 255 : b);

          if (isFloat) {
            floatBuf[dst++] = r * 0.00392156862745098; // r / 255
            floatBuf[dst++] = g * 0.00392156862745098;
            floatBuf[dst++] = b * 0.00392156862745098;
          } else {
            uint8Buf![dst++] =
                (r * qFactor + inputZeroPoint).round().clamp(0, 255);
            uint8Buf[dst++] =
                (g * qFactor + inputZeroPoint).round().clamp(0, 255);
            uint8Buf[dst++] =
                (b * qFactor + inputZeroPoint).round().clamp(0, 255);
          }
        }
      }
    } else {
      // BGRA8888 (iOS غالباً)
      final p0 = frame.plane0;
      final srcW = frame.width;

      for (int ty = 0; ty < inputHeight; ty++) {
        final sy = yMap[ty];
        final rowBase = sy < 0 ? 0 : sy * srcW;
        for (int tx = 0; tx < inputWidth; tx++) {
          final sx = xMap[tx];
          final src = (rowBase + (sx < 0 ? 0 : sx)) << 2;
          final b = sx < 0 || sy < 0 ? 114 : p0[src];
          final g = sx < 0 || sy < 0 ? 114 : p0[src + 1];
          final r = sx < 0 || sy < 0 ? 114 : p0[src + 2];

          if (isFloat) {
            floatBuf[dst++] = r * 0.00392156862745098;
            floatBuf[dst++] = g * 0.00392156862745098;
            floatBuf[dst++] = b * 0.00392156862745098;
          } else {
            uint8Buf![dst++] =
                (r * qFactor + inputZeroPoint).round().clamp(0, 255);
            uint8Buf[dst++] =
                (g * qFactor + inputZeroPoint).round().clamp(0, 255);
            uint8Buf[dst++] =
                (b * qFactor + inputZeroPoint).round().clamp(0, 255);
          }
        }
      }
    }
  }

  // ==========================================================================
  // الاستنتاج ومعالجة المخرجات
  // ==========================================================================

  /// يقرر تلقائياً شكل الـ output:
  ///  - `(1, 300, 6)` end-to-end → قراءة مباشرة، بدون NMS يدوي (المتوقع من w8a32)
  ///  - أي شكل تاني `(1, nc+4, N)` → فك تشفير + NMS يدوي (مسار احتياطي لـ INT8)
  static Map<String, dynamic> _runInference({
    required Interpreter interpreter,
    required TypedData inputBuffer,
    required List<String> labels,
    required double confThreshold,
    required double iouThreshold,
    required _OutputCache? cache,
  }) {
    final outputShape = interpreter.getOutputTensor(0).shape;
    final isEndToEnd = outputShape.length == 3 && outputShape[2] == 6;

    if (isEndToEnd) {
      final out = cache?.endToEnd(outputShape) ?? _allocEndToEnd(outputShape);
      interpreter.run([inputBuffer], out);
      return _parseEndToEnd(out[0], labels, confThreshold);
    } else {
      final out = cache?.raw(outputShape) ?? _allocRaw(outputShape);
      interpreter.run([inputBuffer], out);
      return _parseRawWithNMS(out[0], labels, confThreshold, iouThreshold);
    }
  }

  static List<List<List<double>>> _allocEndToEnd(List<int> shape) =>
      List.generate(1, (_) => List.generate(shape[1], (_) => List.filled(6, 0.0)));

  static List<List<List<double>>> _allocRaw(List<int> shape) => List.generate(
      1, (_) => List.generate(shape[1], (_) => List.filled(shape[2], 0.0)));

  /// `(1, 300, 6)` → [x1, y1, x2, y2, conf, class_id] بإحداثيات مطبّعة 0-1.
  static Map<String, dynamic> _parseEndToEnd(
    List<List<double>> rows,
    List<String> labels,
    double confThreshold,
  ) {
    final detections = <Map<String, dynamic>>[];
    String bestLabel = 'Clear Road';
    double maxScore = 0.0;

    for (final row in rows) {
      final conf = row[4];
      // المخرجات مرتّبة تنازلياً حسب الثقة، فأول صف تحت العتبة = وقف.
      if (conf < confThreshold) break;

      final classId = row[5].round();
      final label = (classId >= 0 && classId < labels.length)
          ? labels[classId]
          : 'Class $classId';

      final coordinateScale =
          (row[0].abs() > 2 || row[1].abs() > 2 || row[2].abs() > 2 || row[3].abs() > 2)
              ? 640.0
              : 1.0;
      detections.add({
        'x1': (row[0] / coordinateScale).clamp(0.0, 1.0),
        'y1': (row[1] / coordinateScale).clamp(0.0, 1.0),
        'x2': (row[2] / coordinateScale).clamp(0.0, 1.0),
        'y2': (row[3] / coordinateScale).clamp(0.0, 1.0),
        'conf': conf,
        'label': label,
      });

      if (conf > maxScore) {
        maxScore = conf;
        bestLabel = label;
      }
    }

    return {
      'label': bestLabel,
      'detections': detections,
      'maxScore': maxScore,
    };
  }

  /// `(1, nc+4, N)` → كل عمود صندوق مرشّح [cx, cy, w, h, scores...] + NMS يدوي.
  static Map<String, dynamic> _parseRawWithNMS(
    List<List<double>> raw,
    List<String> labels,
    double confThreshold,
    double iouThreshold,
  ) {
    final numChannels = raw.length;
    final numAnchors = raw[0].length;
    final numClasses = numChannels - 4;

    final candidates = <List<double>>[];

    for (int a = 0; a < numAnchors; a++) {
      double bestScore = 0.0;
      int bestClass = 0;
      for (int c = 0; c < numClasses; c++) {
        final s = raw[4 + c][a];
        if (s > bestScore) {
          bestScore = s;
          bestClass = c;
        }
      }
      if (bestScore < confThreshold) continue;

      final cx = raw[0][a];
      final cy = raw[1][a];
      final bw = raw[2][a];
      final bh = raw[3][a];

      // بعض صادرات LiteRT تعيد الإحداثيات بوحدة بكسل 640، وبعضها
      // يعيدها مطبّعة. لا نقصّها إلى 1 قبل تحويلها وإلا يصبح كل box شاشة كاملة.
      final coordinateScale = (cx.abs() > 2 || cy.abs() > 2 || bw.abs() > 2 || bh.abs() > 2)
          ? 640.0
          : 1.0;
      candidates.add([
        ((cx - bw / 2) / coordinateScale).clamp(0.0, 1.0),
        ((cy - bh / 2) / coordinateScale).clamp(0.0, 1.0),
        ((cx + bw / 2) / coordinateScale).clamp(0.0, 1.0),
        ((cy + bh / 2) / coordinateScale).clamp(0.0, 1.0),
        bestScore,
        bestClass.toDouble(),
      ]);
    }

    candidates.sort((a, b) => b[4].compareTo(a[4]));

    final kept = <List<double>>[];
    for (final cand in candidates) {
      bool suppressed = false;
      for (final k in kept) {
        if (_iou(cand, k) > iouThreshold) {
          suppressed = true;
          break;
        }
      }
      if (!suppressed) kept.add(cand);
      if (kept.length >= 300) break;
    }

    final detections = <Map<String, dynamic>>[];
    String bestLabel = 'Clear Road';
    double maxScore = 0.0;

    for (final box in kept) {
      final classId = box[5].round();
      final label = (classId >= 0 && classId < labels.length)
          ? labels[classId]
          : 'Class $classId';

      detections.add({
        'x1': box[0],
        'y1': box[1],
        'x2': box[2],
        'y2': box[3],
        'conf': box[4],
        'label': label,
      });

      if (box[4] > maxScore) {
        maxScore = box[4];
        bestLabel = label;
      }
    }

    return {
      'label': bestLabel,
      'detections': detections,
      'maxScore': maxScore,
    };
  }

  static double _iou(List<double> a, List<double> b) {
    final x1 = a[0] > b[0] ? a[0] : b[0];
    final y1 = a[1] > b[1] ? a[1] : b[1];
    final x2 = a[2] < b[2] ? a[2] : b[2];
    final y2 = a[3] < b[3] ? a[3] : b[3];

    final iw = (x2 - x1) > 0 ? (x2 - x1) : 0.0;
    final ih = (y2 - y1) > 0 ? (y2 - y1) : 0.0;
    final inter = iw * ih;

    final areaA = (a[2] - a[0]) * (a[3] - a[1]);
    final areaB = (b[2] - b[0]) * (b[3] - b[1]);
    final union = areaA + areaB - inter;

    return union <= 0 ? 0.0 : inter / union;
  }
}

/// يحتفظ بـ output buffers مخصّصة مرة وحدة ويعيد استخدامها كل فريم.
class _OutputCache {
  _OutputCache(this._interpreter);
  // ignore: unused_field
  final Interpreter _interpreter;

  List<List<List<double>>>? _endToEnd;
  List<List<List<double>>>? _raw;

  List<List<List<double>>> endToEnd(List<int> shape) =>
      _endToEnd ??= TFLiteService._allocEndToEnd(shape);

  List<List<List<double>>> raw(List<int> shape) =>
      _raw ??= TFLiteService._allocRaw(shape);
}

/// بيانات التهيئة المُرسلة للـ isolate مرة واحدة عند الإنشاء.
class _WorkerInit {
  const _WorkerInit({
    required this.mainPort,
    required this.interpreterAddress,
    required this.inputWidth,
    required this.inputHeight,
    required this.inputTypeIndex,
    required this.inputScale,
    required this.inputZeroPoint,
    required this.labels,
    required this.confThreshold,
    required this.iouThreshold,
  });

  final SendPort mainPort;
  final int interpreterAddress;
  final int inputWidth;
  final int inputHeight;
  final int inputTypeIndex;
  final double inputScale;
  final int inputZeroPoint;
  final List<String> labels;
  final double confThreshold;
  final double iouThreshold;
}

/// حمولة فريم واحد مُرسلة للـ isolate.
class _FramePayload {
  const _FramePayload({
    required this.isYuv,
    required this.width,
    required this.height,
    required this.plane0,
    required this.plane1,
    required this.plane2,
    required this.yRowStride,
    required this.uvRowStride,
    required this.uvPixelStride,
  });

  final bool isYuv;
  final int width;
  final int height;
  final Uint8List plane0;
  final Uint8List? plane1;
  final Uint8List? plane2;
  final int yRowStride;
  final int uvRowStride;
  final int uvPixelStride;
}
