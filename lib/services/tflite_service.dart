import 'dart:io';
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
const int _kGpuUsageFastSingleAnswer =
    0; // فريم واحد بكل استدعاء (حالتنا بالضبط)
// ignore: unused_element
const int _kGpuUsageSustainedSpeed = 1; // throughput مستمر (batch) — مش حالتنا

// TfLiteGpuInferencePriority
const int _kGpuPriorityAuto = 0;
// ignore: unused_element
const int _kGpuPriorityMaxPrecision = 1;
const int _kGpuPriorityMinLatency = 2; // ⚡ هدفنا الأول: أقل زمن استجابة
// ignore: unused_element
const int _kGpuPriorityMinMemoryUsage = 3;

/// خدمة الاستنتاج المحلي (YOLO26n / best_float16.tflite).
///
/// تحسينات الأداء المطبّقة:
///  1. GPU delegate بأولوية MIN_LATENCY (بدل MAX_PRECISION الافتراضي).
///  2. الاستنتاج الحي يعمل مؤقتاً على الـ main isolate نفسه الذي أنشأ
///     الـ Interpreter والـ delegate. هذا يمنع خطأ
///     `Bad state: failed precondition` عند استخدام Interpreter داخل worker.
///  3. **Back-pressure**: أي فريم يوصل أثناء التحليل بينرمي فوراً،
///     فما بيتراكم طابور فريمات ويصير التطبيق "متأخر عن الواقع".
///  4. **Frame skipping**: تحليل فريم من كل N (افتراضياً 1 من 3).
///  5. **إعادة استخدام كل الـ buffers** (input + output) بدل تخصيص جديد كل فريم.
///  6. **جداول بحث مسبقة** لإحداثيات العيّنة (sx/sy) — بتلغي قسمة integer
///     لكل بكسل داخل اللوب المتداخل.
///  7. تحويل YUV→RGB + تصغير بمرور واحد على أبعاد الموديل مباشرة.
class TFLiteService {
  // --- الموديل ---
  Interpreter? _interpreter;
  // لازم يظل delegate موجوداً طوال عمر الـ Interpreter. والأهم: نحذفه بعد
  // إغلاقه إذا رفض الـ GPU الـ graph أو عند إغلاق شاشة الكاميرا.
  GpuDelegateV2? _gpuDelegate;
  List<String>? _labels;

  int _inputWidth = 0;
  int _inputHeight = 0;
  bool _inputChannelsFirst = false;
  TensorType _inputType = TensorType.float32;
  double _inputScale = 1.0;
  int _inputZeroPoint = 0;
  String? _startupError;
  String? _lastBackendFailure;
  String _activeBackend = 'unknown';

  // سجل قصير يُعرض داخل شاشة الكاميرا نفسها. لا يحتاج Logcat أو USB، ويحفظ
  // آخر المحاولات فقط حتى لا يغطي معاينة الطريق أو يستهلك الذاكرة.
  final ValueNotifier<List<String>> _diagnosticEvents =
      ValueNotifier<List<String>>(const ['AI | Waiting to initialise…']);

  // --- buffers لمسار الـ main isolate، مخصّصة مرة واحدة ---
  Float32List? _frameFloatBuffer;
  Uint8List? _frameUint8Buffer;
  Int32List? _frameXMap;
  Int32List? _frameYMap;
  _OutputCache? _frameOutputCache;
  int _lastFrameSourceWidth = -1;
  int _lastFrameSourceHeight = -1;
  bool _isRunningFrameInference = false;

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
  static const String _modelAsset = 'assets/best.tflite';

  bool get isReady => _startupError == null && _interpreter != null;
  String? get diagnosticError => _startupError;
  ValueListenable<List<String>> get diagnosticEvents => _diagnosticEvents;

  // ==========================================================================
  // التهيئة
  // ==========================================================================

  Future<void> initializeModel() async {
    if (_interpreter != null) return; // تهيئة مرة وحدة بس

    _addDiagnostic('AI | Loading best_float16.tflite…');
    _interpreter = await _loadInterpreterWithBestDelegate();
    if (_interpreter == null) {
      _startupError ??=
          'Could not run LiteRT model on GPU, NNAPI, or CPU. '
          '${_lastBackendFailure ?? 'No backend accepted the graph.'}';
      _addDiagnostic('AI | STARTUP ERROR | $_startupError');
      debugPrint('❌ $_startupError');
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
    final isNhwc = inputShape.length == 4 && inputShape[3] == 3;
    final isNchw = inputShape.length == 4 && inputShape[1] == 3;
    _inputChannelsFirst = isNchw;
    _inputHeight = isNchw ? inputShape[2] : inputShape[1];
    _inputWidth = isNchw ? inputShape[3] : inputShape[2];
    _inputType = inputTensor.type;
    _inputScale = inputTensor.params.scale;
    _inputZeroPoint = inputTensor.params.zeroPoint;
    final outputTensor = _interpreter!.getOutputTensor(0);
    debugPrint(
      '✅ الموديل جاهز | input: ${_inputWidth}x$_inputHeight '
      '| layout: ${_inputChannelsFirst ? 'NCHW' : 'NHWC'} '
      '| type: $_inputType | q=($_inputScale, $_inputZeroPoint) '
      '| output: ${outputTensor.shape} ${outputTensor.type} '
      'q=(${outputTensor.params.scale}, ${outputTensor.params.zeroPoint}) '
      '| labels: $_labels',
    );

    // فحص مبكر ومقروء بدل خطأ عام عند أول frame. تطبيقنا يدعم YOLO RGB
    // بمخرج float إما end-to-end [1,N,6] أو raw [1,C,N].
    final inputIsSupported =
        inputShape.length == 4 &&
        inputShape[0] == 1 &&
        (isNhwc || isNchw) &&
        (_inputType == TensorType.float32 || _inputType == TensorType.uint8);
    final outputShape = outputTensor.shape;

    // ⚠️ إصلاح مهم: لازم نتأكد إن outputIsEndToEnd و outputIsRaw حالتان
    // متبادلتان (mutually exclusive) ولا يمكن أن تكونا صحيحتين معاً على
    // نفس الـ output tensor. قبل هذا التعديل، موديل end-to-end بشكل
    // [1, 300, 6] كان يحقق outputIsEndToEnd=true (لأن outputShape[2]==6)
    // *و* outputIsRaw=true بنفس الوقت (لأن outputShape[1]=300>=5 و
    // outputShape[2]=6>1). هذا كان يخلي rawClassCount يُحسب خطأ
    // (300-4=296) ويقارَن مع عدد التسميات الحقيقي، فيطلع خطأ وهمي
    // "YOLO model/classes mismatch" حتى لو الموديل end-to-end وسليم 100%.
    //
    // الحل: نستثني صراحة حالة end-to-end من شرط outputIsRaw.
    final outputIsEndToEnd =
        outputShape.length == 3 && outputShape[0] == 1 && outputShape[2] == 6;
    final outputIsRaw =
        !outputIsEndToEnd && // 👈 الإصلاح: يمنع التداخل بين الحالتين
        outputShape.length == 3 &&
        outputShape[0] == 1 &&
        outputShape[1] >= 5 &&
        outputShape[2] > 1;
    final rawClassCount = outputIsRaw ? outputShape[1] - 4 : null;

    // سجل تشخيصي مبكر: يبيّن فوراً أي فرع (end-to-end / raw) تم اختياره
    // وقيمة outputShape الفعلية، بدل ما نكتشف الاختيار الخاطئ من خطأ لاحق.
    debugPrint(
      'ℹ️ output shape=$outputShape | endToEnd=$outputIsEndToEnd '
      '| raw=$outputIsRaw | rawClassCount=$rawClassCount',
    );

    if (!inputIsSupported) {
      _startupError =
          'Unsupported model input: shape=$inputShape type=$_inputType. Expected [1,H,W,3] or [1,3,H,W] float32/uint8.';
    } else if (_labels!.isEmpty) {
      _startupError = 'classes.txt is empty; YOLO labels are required.';
    } else if (outputTensor.type != TensorType.float32) {
      _startupError =
          'Unsupported model output type: ${outputTensor.type}. This build expects float32 output.';
    } else if (!outputIsEndToEnd && !outputIsRaw) {
      _startupError =
          'Unknown YOLO output shape: $outputShape. Expected [1,N,6] or [1,C,N].';
    } else if (rawClassCount != null && rawClassCount != _labels!.length) {
      _startupError =
          'YOLO model/classes mismatch: raw output has $rawClassCount class(es), '
          'but assets/classes.txt has ${_labels!.length} label(s): $_labels.';
    }
    if (_startupError != null) {
      _addDiagnostic('AI | MODEL ERROR | $_startupError');
      debugPrint('❌ $_startupError');
      return;
    }

    final totalPixels = _inputWidth * _inputHeight;
    _frameFloatBuffer = _inputType == TensorType.float32
        ? Float32List(totalPixels * 3)
        : null;
    _frameUint8Buffer = _inputType == TensorType.uint8
        ? Uint8List(totalPixels * 3)
        : null;
    _frameXMap = Int32List(_inputWidth);
    _frameYMap = Int32List(_inputHeight);
    _frameOutputCache = _OutputCache();
    debugPrint(
      '✅ live inference يعمل على main isolate | backend=$_activeBackend',
    );
    _addDiagnostic(
      'AI | Ready | $_activeBackend | input $inputShape | output $outputShape',
    );
  }

  /// ترتيب المحاولات: GPU (min latency) → NNAPI → CPU متعدد الخيوط.
  ///
  /// إنشاء الـ interpreter ليس دليلاً كافياً على أن الـ delegate قادر على
  /// تنفيذ graph. بعض درايفرات NNAPI تقبل موديل W8A32 عند الإنشاء ثم ترفضه
  /// فقط عند أول invoke. لذلك نعمل warm-up حقيقي قبل اعتماد أي backend؛ هذا
  /// يحوّل العطل من خطأ متكرر في الـ live stream إلى fallback آمن للـ CPU.
  Future<Interpreter?> _loadInterpreterWithBestDelegate() async {
    _lastBackendFailure = null;

    // 1) GPU delegate — الأسرع بفارق كبير (بنشمارك: ~4.7ms مقابل ~29ms على CPU)
    Interpreter? interpreter;
    GpuDelegateV2? gpuDelegate;
    try {
      _addDiagnostic('AI | Testing GPU delegate…');
      final gpuOptions = GpuDelegateOptionsV2(
        // يسمح للـ GPU يشتغل بدقة FP16 داخلياً (الموديل نفسه float16 أصلاً)
        // — فرق الدقة مهمل عملياً، والمكسب بالسرعة كبير.
        isPrecisionLossAllowed: true,
        inferencePreference: _kGpuUsageFastSingleAnswer,
        // ⚡ الافتراضي هو MAX_PRECISION — نحن بدنا العكس تماماً.
        inferencePriority1: _kGpuPriorityMinLatency,
        inferencePriority2: _kGpuPriorityAuto,
        inferencePriority3: _kGpuPriorityAuto,
        maxDelegatePartitions: 1,
      );
      try {
        gpuDelegate = GpuDelegateV2(options: gpuOptions);
      } finally {
        gpuOptions.delete();
      }
      final options = InterpreterOptions()..addDelegate(gpuDelegate);
      try {
        interpreter = await Interpreter.fromAsset(
          _modelAsset,
          options: options,
        );
      } finally {
        options.delete();
      }
      _verifyInterpreterCanInvoke(interpreter);
      _gpuDelegate = gpuDelegate;
      _activeBackend = 'GPU';
      debugPrint('✅ GPU delegate اجتاز warm-up (أولوية: أقل زمن استجابة)');
      _addDiagnostic('AI | GPU ready');
      return interpreter;
    } catch (e) {
      interpreter?.close();
      gpuDelegate?.delete();
      _recordBackendFailure('GPU', e);
      debugPrint('⚠️ GPU رفض graph — جرّب NNAPI...');
    }

    // 2) NNAPI — بيستغل أي مسرّع بالشريحة (NPU/DSP/GPU)
    interpreter = null;
    try {
      _addDiagnostic('AI | Testing NNAPI delegate…');
      final options = InterpreterOptions()..useNnApiForAndroid = true;
      try {
        interpreter = await Interpreter.fromAsset(
          _modelAsset,
          options: options,
        );
      } finally {
        options.delete();
      }
      _verifyInterpreterCanInvoke(interpreter);
      _activeBackend = 'NNAPI';
      debugPrint('✅ NNAPI delegate اجتاز warm-up');
      _addDiagnostic('AI | NNAPI ready');
      return interpreter;
    } catch (e) {
      interpreter?.close();
      _recordBackendFailure('NNAPI', e);
      debugPrint('⚠️ NNAPI رفض graph — رجوع لـ CPU...');
    }

    return _loadCpuInterpreter();
  }

  /// CPU/XNNPACK هو المسار المرجعي الذي يدعم الموديل حتى لو درايفر NNAPI
  /// الخاص بالجهاز لا يدعم W8A32 أو أحد operators المصدّرة من YOLO.
  Future<Interpreter?> _loadCpuInterpreter() async {
    Interpreter? interpreter;
    try {
      final cores = Platform.numberOfProcessors;
      final threads = cores > 4 ? 4 : (cores < 1 ? 1 : cores);
      final options = InterpreterOptions()..threads = threads;
      debugPrint('ℹ️ CPU fallback بـ $threads خيوط');
      _addDiagnostic('AI | Testing CPU/XNNPACK ($threads threads)…');
      try {
        interpreter = await Interpreter.fromAsset(
          _modelAsset,
          options: options,
        );
      } finally {
        options.delete();
      }
      _verifyInterpreterCanInvoke(interpreter);
      _activeBackend = 'CPU/XNNPACK ($threads threads)';
      debugPrint('✅ CPU/XNNPACK اجتاز warm-up');
      _addDiagnostic('AI | CPU/XNNPACK ready');
      return interpreter;
    } catch (e) {
      interpreter?.close();
      _recordBackendFailure('CPU/XNNPACK', e);
      debugPrint('❌ حتى CPU رفض graph: $e');
      return null;
    }
  }

  /// لا نكتفي بـ [Interpreter.fromAsset]: ننسخ input صفر بطول tensor الحقيقي
  /// ونستدعي graph. الـ bytes الصفرية صالحة لكل الأنواع المدعومة، والهدف هنا
  /// اختبار توافق الـ backend فقط وليس التنبؤ بصوره حقيقية.
  static void _verifyInterpreterCanInvoke(Interpreter interpreter) {
    final input = interpreter.getInputTensor(0);
    input.setTo(Uint8List(input.numBytes()));
    interpreter.invoke();
  }

  void _recordBackendFailure(String backend, Object error) {
    _lastBackendFailure = '$backend warm-up failed: $error';
    _addDiagnostic('AI | $backend rejected graph | ${_shortError(error)}');
    debugPrint('⚠️ $_lastBackendFailure');
  }

  void _addDiagnostic(String event) {
    const maxEvents = 5;
    final next = <String>[..._diagnosticEvents.value, event];
    if (next.length > maxEvents) {
      next.removeRange(0, next.length - maxEvents);
    }
    _diagnosticEvents.value = List<String>.unmodifiable(next);
  }

  static String _shortError(Object error) {
    final singleLine = error.toString().replaceAll(RegExp(r'\s+'), ' ').trim();
    return singleLine.length <= 96
        ? singleLine
        : '${singleLine.substring(0, 93)}…';
  }

  bool get _isAcceleratedBackend =>
      _activeBackend == 'GPU' || _activeBackend == 'NNAPI';

  /// حماية إضافية: إذا درايفر المسرّع انهار بعد warm-up، أعد إنشاء interpreter
  /// على CPU وأعد تجربة الفريم نفسه مرة واحدة بدل عرض الخطأ بكل فريم.
  Future<void> _fallbackToCpuAfterInvokeFailure(Object cause) async {
    final failedBackend = _activeBackend;
    debugPrint(
      '⚠️ $failedBackend invoke فشل بعد warm-up ($cause) — التحويل إلى CPU...',
    );
    _addDiagnostic(
      'AI | $failedBackend invoke failed | Switching to CPU/XNNPACK…',
    );

    final oldInterpreter = _interpreter;
    final oldGpuDelegate = _gpuDelegate;
    _interpreter = null;
    _gpuDelegate = null;
    _activeBackend = 'unknown';
    oldInterpreter?.close();
    oldGpuDelegate?.delete();

    final cpuInterpreter = await _loadCpuInterpreter();
    if (cpuInterpreter == null) {
      throw StateError(
        'CPU fallback failed after $failedBackend: '
        '${_lastBackendFailure ?? cause}',
      );
    }
    _interpreter = cpuInterpreter;
    _frameOutputCache = _OutputCache();
  }

  void dispose() {
    _interpreter?.close();
    _gpuDelegate?.delete();
    _interpreter = null;
    _gpuDelegate = null;
    _frameFloatBuffer = null;
    _frameUint8Buffer = null;
    _frameXMap = null;
    _frameYMap = null;
    _frameOutputCache = null;
    _lastFrameSourceWidth = -1;
    _lastFrameSourceHeight = -1;
    _isRunningFrameInference = false;
    _activeBackend = 'unknown';
    _lastBackendFailure = null;
    _startupError = null;
    _diagnosticEvents.dispose();
  }

  // ==========================================================================
  // DASHCAM MODE — فريم كاميرا حي
  // ==========================================================================

  /// يرجّع `{'label': String, 'detections': List<Map>}` عند التحليل الفعلي.
  ///
  /// ⚠️ يرجّع **null** (مش نتيجة فاضية) إذا:
  ///  - الفريم ضمن الفريمات المتخطّاة (frame skipping)، أو
  ///  - التحليل السابق ما زال مشغولاً (back-pressure).
  ///
  /// التمييز بين null و'Clear Road' حرج: بدونه الفريم المتخطّى بينقرأ كأنه
  /// "طريق نظيف" فبيمسح المربعات من الشاشة ويصفّر عدّاد التأكيد الزمني.
  Future<Map<String, dynamic>?> predictFrameWithBoxes(
    CameraImage cameraImage,
  ) async {
    if (!isReady) return null;

    // 1) تخطي فريمات
    _frameCounter++;
    if (frameSkipRate > 1 && _frameCounter % frameSkipRate != 0) return null;

    // 2) رمي الفريم لو التحليل مشغول (لا طابور، لا تأخير تراكمي).
    if (_isRunningFrameInference) return null;

    var stage = 'build camera frame';
    try {
      _isRunningFrameInference = true;
      final frame = _FramePayload(
        isYuv: cameraImage.format.group == ImageFormatGroup.yuv420,
        width: cameraImage.width,
        height: cameraImage.height,
        plane0: cameraImage.planes[0].bytes,
        plane1: cameraImage.planes.length > 1
            ? cameraImage.planes[1].bytes
            : null,
        plane2: cameraImage.planes.length > 2
            ? cameraImage.planes[2].bytes
            : null,
        yRowStride: cameraImage.planes[0].bytesPerRow,
        uvRowStride: cameraImage.planes.length > 1
            ? cameraImage.planes[1].bytesPerRow
            : 0,
        uvPixelStride: cameraImage.planes.length > 1
            ? (cameraImage.planes[1].bytesPerPixel ?? 1)
            : 1,
      );

      stage = 'letterbox mapping';
      _updateFrameLetterboxMaps(frame);
      stage = 'YUV/BGRA → RGB input buffer';
      _fillInputBuffer(
        frame: frame,
        inputWidth: _inputWidth,
        inputHeight: _inputHeight,
        xMap: _frameXMap!,
        yMap: _frameYMap!,
        floatBuf: _frameFloatBuffer,
        uint8Buf: _frameUint8Buffer,
        channelsFirst: _inputChannelsFirst,
        inputScale: _inputScale,
        inputZeroPoint: _inputZeroPoint,
      );
      stage = 'LiteRT inference';
      return _runInference(
        interpreter: _interpreter!,
        inputBuffer: (_frameFloatBuffer ?? _frameUint8Buffer)!,
        labels: _labels!,
        confThreshold: _confThreshold,
        iouThreshold: _iouThreshold,
        cache: _frameOutputCache,
      );
    } catch (e, stack) {
      Object error = e;
      StackTrace errorStack = stack;
      if (error is _InferenceStageException &&
          error.stage == 'invoke LiteRT graph' &&
          _isAcceleratedBackend) {
        try {
          await _fallbackToCpuAfterInvokeFailure(error.cause);
          return _runInference(
            interpreter: _interpreter!,
            inputBuffer: (_frameFloatBuffer ?? _frameUint8Buffer)!,
            labels: _labels!,
            confThreshold: _confThreshold,
            iouThreshold: _iouThreshold,
            cache: _frameOutputCache,
          );
        } catch (fallbackError, fallbackStack) {
          error = _InferenceStageException(
            'CPU fallback after accelerated invoke',
            '$fallbackError\n$fallbackStack',
          );
          errorStack = fallbackStack;
        }
      }
      final detail = error is _InferenceStageException
          ? error.message
          : '$stage: $error';
      debugPrint('❌ AI error | backend=$_activeBackend | $detail');
      _addDiagnostic('AI | ERROR | $_activeBackend | ${_shortError(detail)}');
      return {
        ..._empty,
        'maxScore': 0.0,
        'error': 'backend=$_activeBackend | $detail\n$errorStack',
      };
    } finally {
      _isRunningFrameInference = false;
    }
  }

  /// يحدث خرائط letterbox فقط عندما تتغير أبعاد صورة الكاميرا.
  void _updateFrameLetterboxMaps(_FramePayload frame) {
    if (frame.width == _lastFrameSourceWidth &&
        frame.height == _lastFrameSourceHeight) {
      return;
    }

    final resizeScale =
        (_inputWidth / frame.width) < (_inputHeight / frame.height)
        ? (_inputWidth / frame.width)
        : (_inputHeight / frame.height);
    final resizedW = (frame.width * resizeScale).round();
    final resizedH = (frame.height * resizeScale).round();
    final padX = (_inputWidth - resizedW) ~/ 2;
    final padY = (_inputHeight - resizedH) ~/ 2;

    for (int tx = 0; tx < _inputWidth; tx++) {
      final sourceX = ((tx - padX) / resizeScale).floor();
      _frameXMap![tx] = sourceX < 0 || sourceX >= frame.width ? -1 : sourceX;
    }
    for (int ty = 0; ty < _inputHeight; ty++) {
      final sourceY = ((ty - padY) / resizeScale).floor();
      _frameYMap![ty] = sourceY < 0 || sourceY >= frame.height ? -1 : sourceY;
    }
    _lastFrameSourceWidth = frame.width;
    _lastFrameSourceHeight = frame.height;
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
      final scale =
          (_inputWidth / decoded.width) < (_inputHeight / decoded.height)
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
        for (int y = 0; y < _inputHeight; y++) {
          for (int x = 0; x < _inputWidth; x++) {
            final inImage =
                x >= padX &&
                x < padX + resizedW &&
                y >= padY &&
                y < padY + resizedH;
            final p = inImage ? source.getPixel(x - padX, y - padY) : null;
            final pixel = y * _inputWidth + x;
            final base = _inputChannelsFirst ? pixel : pixel * 3;
            f[base] = (p?.r ?? 114) / 255.0;
            f[_inputChannelsFirst ? totalPixels + pixel : base + 1] =
                (p?.g ?? 114) / 255.0;
            f[_inputChannelsFirst ? totalPixels * 2 + pixel : base + 2] =
                (p?.b ?? 114) / 255.0;
          }
        }
        buffer = f;
      } else {
        final u = Uint8List(totalPixels * 3);
        final scale = _inputScale == 0 ? 1.0 : _inputScale;
        for (int y = 0; y < _inputHeight; y++) {
          for (int x = 0; x < _inputWidth; x++) {
            final inImage =
                x >= padX &&
                x < padX + resizedW &&
                y >= padY &&
                y < padY + resizedH;
            final p = inImage ? source.getPixel(x - padX, y - padY) : null;
            final pixel = y * _inputWidth + x;
            final base = _inputChannelsFirst ? pixel : pixel * 3;
            u[base] = (((p?.r ?? 114) / 255.0) / scale + _inputZeroPoint)
                .round()
                .clamp(0, 255);
            u[_inputChannelsFirst ? totalPixels + pixel : base + 1] =
                (((p?.g ?? 114) / 255.0) / scale + _inputZeroPoint)
                    .round()
                    .clamp(0, 255);
            u[_inputChannelsFirst ? totalPixels * 2 + pixel : base + 2] =
                (((p?.b ?? 114) / 255.0) / scale + _inputZeroPoint)
                    .round()
                    .clamp(0, 255);
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

  static Map<String, dynamic> get _empty => {
    'label': 'Clear Road',
    'detections': const <Map<String, dynamic>>[],
  };

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
    required bool channelsFirst,
    required double inputScale,
    required int inputZeroPoint,
  }) {
    final bool isFloat = floatBuf != null;
    final double scale = inputScale == 0 ? 1.0 : inputScale;
    // للتكميم: نحسب المعامل مرة وحدة برا اللوب بدل قسمة لكل قناة لكل بكسل.
    final double qFactor = 1.0 / (255.0 * scale);

    final totalPixels = inputWidth * inputHeight;
    int pixel = 0;

    void writePixel(int r, int g, int b) {
      final base = channelsFirst ? pixel : pixel * 3;
      if (isFloat) {
        floatBuf[base] = r * 0.00392156862745098;
        floatBuf[channelsFirst ? totalPixels + pixel : base + 1] =
            g * 0.00392156862745098;
        floatBuf[channelsFirst ? totalPixels * 2 + pixel : base + 2] =
            b * 0.00392156862745098;
      } else {
        uint8Buf![base] = (r * qFactor + inputZeroPoint).round().clamp(0, 255);
        uint8Buf[channelsFirst ? totalPixels + pixel : base + 1] =
            (g * qFactor + inputZeroPoint).round().clamp(0, 255);
        uint8Buf[channelsFirst ? totalPixels * 2 + pixel : base + 2] =
            (b * qFactor + inputZeroPoint).round().clamp(0, 255);
      }
      pixel++;
    }

    if (frame.isYuv) {
      final p0 = frame.plane0;
      final p1 = frame.plane1;
      final p2 = frame.plane2;
      if (p1 == null || p2 == null) {
        throw Exception('YUV420 بدون chroma planes');
      }

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

          writePixel(r, g, b);
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

          writePixel(r, g, b);
        }
      }
    }
  }

  // ==========================================================================
  // الاستنتاج ومعالجة المخرجات
  // ==========================================================================

  /// يقرر تلقائياً شكل الـ output:
  ///  - `(1, 300, 6)` end-to-end من export بـ `nms=True` → قراءة مباشرة.
  ///  - `(1, nc+4, N)` من export بـ `nms=False` → فك تشفير + NMS يدوي.
  static Map<String, dynamic> _runInference({
    required Interpreter interpreter,
    required TypedData inputBuffer,
    required List<String> labels,
    required double confThreshold,
    required double iouThreshold,
    required _OutputCache? cache,
  }) {
    late final List<int> outputShape;
    try {
      outputShape = interpreter.getOutputTensor(0).shape;
    } catch (e) {
      throw _InferenceStageException('read output tensor metadata', e);
    }
    final isEndToEnd = outputShape.length == 3 && outputShape[2] == 6;

    // tflite_flutter يعامل Float32List كـ List ذات بُعد واحد ويعيد تحجيم
    // الإدخال إلى [1228800]. تمرير ByteBuffer يمنع هذا الـ resize الخاطئ
    // ويحافظ على [1,3,640,640] / [1,640,640,3] الفعلي للموديل.
    final ByteBuffer modelInput = inputBuffer.buffer;
    try {
      interpreter.getInputTensor(0).setTo(modelInput);
    } catch (e) {
      throw _InferenceStageException('copy input to tensor', e);
    }

    try {
      interpreter.invoke();
    } catch (e) {
      throw _InferenceStageException('invoke LiteRT graph', e);
    }

    if (isEndToEnd) {
      final out = cache?.endToEnd(outputShape) ?? _allocEndToEnd(outputShape);
      try {
        interpreter.getOutputTensor(0).copyTo(out);
      } catch (e) {
        throw _InferenceStageException('copy output tensor', e);
      }
      try {
        return _parseEndToEnd(out[0], labels, confThreshold);
      } catch (e) {
        throw _InferenceStageException('parse end-to-end output', e);
      }
    } else {
      final out = cache?.raw(outputShape) ?? _allocRaw(outputShape);
      try {
        interpreter.getOutputTensor(0).copyTo(out);
      } catch (e) {
        throw _InferenceStageException('copy output tensor', e);
      }
      try {
        return _parseRawWithNMS(out[0], labels, confThreshold, iouThreshold);
      } catch (e) {
        throw _InferenceStageException('parse raw output + NMS', e);
      }
    }
  }

  static List<List<List<double>>> _allocEndToEnd(List<int> shape) =>
      List.generate(
        1,
        (_) => List.generate(shape[1], (_) => List.filled(6, 0.0)),
      );

  static List<List<List<double>>> _allocRaw(List<int> shape) => List.generate(
    1,
    (_) => List.generate(shape[1], (_) => List.filled(shape[2], 0.0)),
  );

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
          (row[0].abs() > 2 ||
              row[1].abs() > 2 ||
              row[2].abs() > 2 ||
              row[3].abs() > 2)
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

    return {'label': bestLabel, 'detections': detections, 'maxScore': maxScore};
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
      final coordinateScale =
          (cx.abs() > 2 || cy.abs() > 2 || bw.abs() > 2 || bh.abs() > 2)
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

    return {'label': bestLabel, 'detections': detections, 'maxScore': maxScore};
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
  List<List<List<double>>>? _endToEnd;
  List<List<List<double>>>? _raw;

  List<List<List<double>>> endToEnd(List<int> shape) =>
      _endToEnd ??= TFLiteService._allocEndToEnd(shape);

  List<List<List<double>>> raw(List<int> shape) =>
      _raw ??= TFLiteService._allocRaw(shape);
}

/// يربط خطأ LiteRT بمرحلة محددة ليظهر في لوحة تشخيص الكاميرا.
class _InferenceStageException implements Exception {
  _InferenceStageException(this.stage, this.cause);

  final String stage;
  final Object cause;

  String get message => '$stage: $cause';

  @override
  String toString() => message;
}

/// حمولة فريم واحد تُعالج مباشرة على الـ main isolate.
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