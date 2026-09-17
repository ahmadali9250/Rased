import 'dart:io';
import 'dart:typed_data';
import 'package:camera/camera.dart';
import 'package:tflite_flutter/tflite_flutter.dart';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

/// ⚠️ لازم تتأكدوا من هاد قبل ما تشغّلوا: الموديل المصدَّر بـ export_model.py يستخدم
/// nms=False، يعني output tensor شكله (1, 300, 6) => [x1, y1, x2, y2, conf, class_id]
/// بإحداثيات مطبّعة (0-1). لو صدّرتوا بإعدادات مختلفة لازم تعدّلوا _parseDetections.
class TFLiteService {
  Interpreter? _interpreter;
  List<String>? _labels;

  int _inputWidth = 0;
  int _inputHeight = 0;
  TensorType _inputType = TensorType.float32;
  double _inputScale = 1.0;
  int _inputZeroPoint = 0;

  static const double _confThreshold = 0.35; // كان 0.20 بالكود القديم — رفعناه لتقليل false positives
  static const String _modelAsset = 'assets/best_w8a32.tflite'; // النسخة النهائية المعتمدة — أدق نسخة تقريباً بنفس دقة FP32 وبثلث حجمه

  Future<void> initializeModel() async {
    _interpreter = await _loadInterpreterWithBestDelegate();
    if (_interpreter == null) {
      debugPrint('❌ فشل تحميل الموديل نهائياً (GPU وCPU الاثنين فشلوا)');
      return;
    }

    final labelFile = await rootBundle.loadString('assets/classes.txt');
    _labels = labelFile.split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty).toList();

    final inputTensor = _interpreter!.getInputTensor(0);
    final inputShape = inputTensor.shape;
    _inputHeight = inputShape[1];
    _inputWidth = inputShape[2];
    _inputType = inputTensor.type;
    _inputScale = inputTensor.params.scale;
    _inputZeroPoint = inputTensor.params.zeroPoint;

    debugPrint(
      '✅ الموديل جاهز | input: ${_inputWidth}x$_inputHeight | type: $_inputType | labels: $_labels',
    );
  }

  /// يجرّب GPU delegate أول شي، ولو فشل (جهاز قديم / درايفر ما بيدعم) يرجع لـ NNAPI،
  /// ولو هاد كمان فشل، يرجع CPU عادي (XNNPACK الافتراضي) بدل ما يطيح التطبيق كامل.
  Future<Interpreter?> _loadInterpreterWithBestDelegate() async {
    // 1) GPU (الأسرع بكثير حسب البنشمارك — GPU ~4.7ms مقابل CPU ~29ms لموديل مشابه)
    try {
      final gpuDelegate = GpuDelegateV2(
        options: GpuDelegateOptionsV2(
          isPrecisionLossAllowed: true,
          inferencePreference: TfLiteGpuInferenceUsage.fastSingleAnswer,
          inferencePriority1: TfLiteGpuInferencePriority.minLatency,
          inferencePriority2: TfLiteGpuInferencePriority.auto,
          inferencePriority3: TfLiteGpuInferencePriority.auto,
        ),
      );
      final options = InterpreterOptions()..addDelegate(gpuDelegate);
      final interpreter = await Interpreter.fromAsset(_modelAsset, options: options);
      debugPrint('✅ GPU delegate اشتغل');
      return interpreter;
    } catch (e) {
      debugPrint('⚠️ GPU delegate فشل ($e) — جرّب NNAPI...');
    }

    // 2) NNAPI (Android فقط — بيستخدم أي مسرّع متوفر بالجهاز: DSP/NPU/GPU حسب الشريحة)
    try {
      final options = InterpreterOptions()..useNnApiForAndroid = true;
      final interpreter = await Interpreter.fromAsset(_modelAsset, options: options);
      debugPrint('✅ NNAPI delegate اشتغل');
      return interpreter;
    } catch (e) {
      debugPrint('⚠️ NNAPI فشل ($e) — رجوع لـ CPU عادي...');
    }

    // 3) CPU عادي (fallback أخير — أفضل من ما يفتح التطبيق إطلاقاً)
    try {
      final options = InterpreterOptions()..threads = 4;
      return await Interpreter.fromAsset(_modelAsset, options: options);
    } catch (e) {
      debugPrint('❌ حتى CPU فشل: $e');
      return null;
    }
  }

  void dispose() {
    _interpreter?.close();
  }

  // ============================================================
  // MANUAL MODE — صورة ثابتة
  // ============================================================
  Future<Map<String, dynamic>> predictImage(String imagePath) async {
    if (_interpreter == null || _labels == null) return {'label': 'Clear Road', 'detections': []};
    try {
      final imageData = File(imagePath).readAsBytesSync();
      final image = img.decodeImage(imageData);
      if (image == null) return {'label': 'Clear Road', 'detections': []};
      return _runOnDecodedImage(image, _interpreter!, _labels!, _inputWidth, _inputHeight,
          _inputType, _inputScale, _inputZeroPoint);
    } catch (e) {
      return {'label': 'Clear Road', 'detections': []};
    }
  }

  // ============================================================
  // DASHCAM MODE — فريم كاميرا حي (بالخلفية، برا الـ UI thread)
  // ============================================================
  Future<Map<String, dynamic>> predictFrameWithBoxes(CameraImage cameraImage) async {
    if (_interpreter == null || _labels == null) {
      return {'label': 'Clear Road', 'detections': []};
    }
    try {
      return await compute(_processFrameInIsolate, {
        'format': cameraImage.format.group == ImageFormatGroup.yuv420 ? 'yuv420' : 'bgra8888',
        'width': cameraImage.width,
        'height': cameraImage.height,
        'plane0': cameraImage.planes[0].bytes,
        'plane1': cameraImage.planes.length > 1 ? cameraImage.planes[1].bytes : null,
        'plane2': cameraImage.planes.length > 2 ? cameraImage.planes[2].bytes : null,
        'yRowStride': cameraImage.planes[0].bytesPerRow,
        'uvRowStride': cameraImage.planes.length > 1 ? cameraImage.planes[1].bytesPerRow : 0,
        'uvPixelStride':
            cameraImage.planes.length > 1 ? (cameraImage.planes[1].bytesPerPixel ?? 0) : 0,
        'inputWidth': _inputWidth,
        'inputHeight': _inputHeight,
        'inputType': _inputType.index,
        'inputScale': _inputScale,
        'inputZeroPoint': _inputZeroPoint,
        'interpreterAddress': _interpreter!.address,
        'labels': _labels,
      });
    } catch (e) {
      debugPrint('❌ خطأ بمعالجة الفريم: $e');
      return {'label': 'Clear Road', 'detections': []};
    }
  }

  // للتوافق الخلفي مع أي كود قديم بيتوقع String بس
  Future<String> predictFrame(CameraImage cameraImage) async {
    final result = await predictFrameWithBoxes(cameraImage);
    return result['label'] as String? ?? 'Clear Road';
  }

  static Map<String, dynamic> _processFrameInIsolate(Map<String, dynamic> params) {
    try {
      final int width = params['width'];
      final int height = params['height'];
      final int inputWidth = params['inputWidth'];
      final int inputHeight = params['inputHeight'];
      final TensorType inputType = TensorType.values[params['inputType']];
      final double inputScale = params['inputScale'];
      final int inputZeroPoint = params['inputZeroPoint'];
      final int address = params['interpreterAddress'];
      final labels = (params['labels'] as List<dynamic>).map((e) => e.toString()).toList();
      final interpreter = Interpreter.fromAddress(address);

      // تحويل اللون + تصغير الحجم بمرور واحد بس، على أبعاد المودل مباشرة (640×640 مثلاً)
      // بدل تحويل الفريم كامل (ممكن يكون 1080p+) لصورة RGB كاملة الأبعاد ثم تصغيرها لاحقاً.
      // هاد لوحده بيقلل عدد البكسلات المعالَجة بعشرات المرات.
      final inputBuffer = _buildInputBufferDirect(
        params: params,
        width: width,
        height: height,
        inputWidth: inputWidth,
        inputHeight: inputHeight,
        inputType: inputType,
        inputScale: inputScale,
        inputZeroPoint: inputZeroPoint,
      );

      return _runInterpreterWithBuffer(interpreter, inputBuffer, inputType, labels);
    } catch (e) {
      return {'label': 'Clear Road', 'detections': []};
    }
  }

  /// يبني الـ input buffer مباشرة من بيانات الكاميرا الخام (YUV420 أو BGRA8888)،
  /// بأخذ عيّنة nearest-neighbor على أبعاد المودل مباشرة — بدون تحويل الصورة كاملة أول.
  static TypedData _buildInputBufferDirect({
    required Map<String, dynamic> params,
    required int width,
    required int height,
    required int inputWidth,
    required int inputHeight,
    required TensorType inputType,
    required double inputScale,
    required int inputZeroPoint,
  }) {
    final String format = params['format'];
    final int totalPixels = inputWidth * inputHeight;

    final Float32List? floatBuffer =
        inputType == TensorType.float32 ? Float32List(totalPixels * 3) : null;
    final Uint8List? uint8Buffer =
        inputType != TensorType.float32 ? Uint8List(totalPixels * 3) : null;

    void writePixel(int destIndex, int r, int g, int b) {
      if (floatBuffer != null) {
        floatBuffer[destIndex] = r / 255.0;
        floatBuffer[destIndex + 1] = g / 255.0;
        floatBuffer[destIndex + 2] = b / 255.0;
      } else {
        // تكميم: quantized = round(real_value / scale) + zero_point
        int q(int channel255) {
          final real = channel255 / 255.0;
          final scale = inputScale == 0 ? 1.0 : inputScale;
          return (real / scale + inputZeroPoint).round().clamp(0, 255);
        }

        uint8Buffer![destIndex] = q(r);
        uint8Buffer[destIndex + 1] = q(g);
        uint8Buffer[destIndex + 2] = q(b);
      }
    }

    if (format == 'yuv420') {
      final Uint8List plane0 = params['plane0'];
      final Uint8List? plane1 = params['plane1'];
      final Uint8List? plane2 = params['plane2'];
      final int yRowStride = params['yRowStride'];
      final int uvRowStride = params['uvRowStride'];
      final int uvPixelStride = params['uvPixelStride'];

      if (plane1 == null || plane2 == null) {
        throw Exception('YUV420 بدون chroma planes');
      }

      for (int ty = 0; ty < inputHeight; ty++) {
        final int sy = (ty * height ~/ inputHeight).clamp(0, height - 1);
        for (int tx = 0; tx < inputWidth; tx++) {
          final int sx = (tx * width ~/ inputWidth).clamp(0, width - 1);

          final int uvIndex = uvPixelStride * (sx ~/ 2) + uvRowStride * (sy ~/ 2);
          final int yIndex = sy * yRowStride + sx;

          final int yp = plane0[yIndex];
          final int up = plane1[uvIndex];
          final int vp = plane2[uvIndex];

          final int r = (yp + vp * 1436 / 1024 - 179).round().clamp(0, 255);
          final int g =
              (yp - up * 46549 / 131072 + 44 - vp * 93604 / 131072 + 91).round().clamp(0, 255);
          final int b = (yp + up * 1814 / 1024 - 227).round().clamp(0, 255);

          final int destIndex = (ty * inputWidth + tx) * 3;
          writePixel(destIndex, r, g, b);
        }
      }
    } else {
      // bgra8888 (iOS غالباً)
      final Uint8List plane0 = params['plane0'];
      for (int ty = 0; ty < inputHeight; ty++) {
        final int sy = (ty * height ~/ inputHeight).clamp(0, height - 1);
        for (int tx = 0; tx < inputWidth; tx++) {
          final int sx = (tx * width ~/ inputWidth).clamp(0, width - 1);
          final int srcIndex = (sy * width + sx) * 4;

          final int b = plane0[srcIndex];
          final int g = plane0[srcIndex + 1];
          final int r = plane0[srcIndex + 2];

          final int destIndex = (ty * inputWidth + tx) * 3;
          writePixel(destIndex, r, g, b);
        }
      }
    }

    return floatBuffer ?? uint8Buffer!;
  }

  static Map<String, dynamic> _runOnDecodedImage(
    img.Image image,
    Interpreter interpreter,
    List<String> labels,
    int inputWidth,
    int inputHeight,
    TensorType inputType,
    double inputScale,
    int inputZeroPoint,
  ) {
    final resized = img.copyResize(image, width: inputWidth, height: inputHeight);
    final totalPixels = inputWidth * inputHeight;

    final TypedData buffer;
    if (inputType == TensorType.float32) {
      final f = Float32List(totalPixels * 3);
      int i = 0;
      for (int y = 0; y < inputHeight; y++) {
        for (int x = 0; x < inputWidth; x++) {
          final p = resized.getPixel(x, y);
          f[i++] = p.r / 255.0;
          f[i++] = p.g / 255.0;
          f[i++] = p.b / 255.0;
        }
      }
      buffer = f;
    } else {
      final u = Uint8List(totalPixels * 3);
      final scale = inputScale == 0 ? 1.0 : inputScale;
      int i = 0;
      for (int y = 0; y < inputHeight; y++) {
        for (int x = 0; x < inputWidth; x++) {
          final p = resized.getPixel(x, y);
          u[i++] = ((p.r / 255.0) / scale + inputZeroPoint).round().clamp(0, 255);
          u[i++] = ((p.g / 255.0) / scale + inputZeroPoint).round().clamp(0, 255);
          u[i++] = ((p.b / 255.0) / scale + inputZeroPoint).round().clamp(0, 255);
        }
      }
      buffer = u;
    }

    return _runInterpreterWithBuffer(interpreter, buffer, inputType, labels);
  }

  /// يشغّل الاستنتاج ويقرر تلقائياً شكل الـ output ويتعامل معه:
  /// - end2end: (1, 300, 6) [x1,y1,x2,y2,conf,class_id] — يطلع من FP32/w8a32 (nms=False اشتغل)
  /// - raw:     (1, nc+4, N) — يطلع من INT8 تحديداً (Ultralytics بيعطّل end2end تلقائياً مع
  ///   تكميم INT8 الثابت، بغض النظر شو مررنا بـ nms=)، فمحتاج فك تشفير + NMS يدوي هون.
  static Map<String, dynamic> _runInterpreterWithBuffer(
    Interpreter interpreter,
    TypedData inputBuffer,
    TensorType inputType,
    List<String> labels,
  ) {
    final outputTensor = interpreter.getOutputTensor(0);
    final outputShape = outputTensor.shape; // [1, 300, 6] أو [1, nc+4, N]

    final bool isEndToEnd = outputShape.length == 3 && outputShape[2] == 6;

    if (isEndToEnd) {
      return _parseEndToEndOutput(interpreter, inputBuffer, outputShape, labels);
    } else {
      return _parseRawOutputWithNMS(interpreter, inputBuffer, outputShape, labels);
    }
  }

  /// شكل جاهز (1, 300, 6): [x1, y1, x2, y2, conf, class_id] — بدون أي فك تشفير أو NMS يدوي.
  static Map<String, dynamic> _parseEndToEndOutput(
    Interpreter interpreter,
    TypedData inputBuffer,
    List<int> outputShape,
    List<String> labels,
  ) {
    final maxDet = outputShape[1];
    final outputBuffer =
        List.generate(1, (_) => List.generate(maxDet, (_) => List.filled(6, 0.0)));

    interpreter.run([inputBuffer], outputBuffer);

    final parsed = outputBuffer[0] as List<List<double>>;
    final detections = <Map<String, dynamic>>[];

    String bestLabel = 'Clear Road';
    double maxScore = 0.0;

    for (final row in parsed) {
      final double conf = row[4];
      if (conf < _confThreshold) continue;

      final int classId = row[5].round();
      final String label =
          (classId >= 0 && classId < labels.length) ? labels[classId] : 'Class $classId';

      detections.add({
        'x1': row[0].clamp(0.0, 1.0),
        'y1': row[1].clamp(0.0, 1.0),
        'x2': row[2].clamp(0.0, 1.0),
        'y2': row[3].clamp(0.0, 1.0),
        'conf': conf,
        'label': label,
      });

      if (conf > maxScore) {
        maxScore = conf;
        bestLabel = label;
      }
    }

    return {'label': bestLabel, 'detections': detections};
  }

  /// شكل خام (1, nc+4, N): كل عمود = صندوق مرشّح [cx, cy, w, h, score_class0, score_class1, ...]
  /// (إحداثيات cx/cy/w/h مطبّعة 0-1). لازم فك تشفير + NMS يدوي هون لأنه ما في NMS جوا الموديل.
  static Map<String, dynamic> _parseRawOutputWithNMS(
    Interpreter interpreter,
    TypedData inputBuffer,
    List<int> outputShape,
    List<String> labels,
  ) {
    final int numChannels = outputShape[1]; // nc + 4
    final int numAnchors = outputShape[2];
    final int numClasses = numChannels - 4;

    final outputBuffer = List.generate(
      1,
      (_) => List.generate(numChannels, (_) => List.filled(numAnchors, 0.0)),
    );

    interpreter.run([inputBuffer], outputBuffer);
    final raw = outputBuffer[0] as List<List<double>>;

    // كل مرشّح: [cx, cy, w, h, conf, classId, x1, y1, x2, y2] — منجمعهم هون قبل NMS
    final candidates = <List<double>>[];

    for (int a = 0; a < numAnchors; a++) {
      double bestScore = 0.0;
      int bestClass = 0;
      for (int c = 0; c < numClasses; c++) {
        final double score = raw[4 + c][a];
        if (score > bestScore) {
          bestScore = score;
          bestClass = c;
        }
      }
      if (bestScore < _confThreshold) continue;

      final double cx = raw[0][a];
      final double cy = raw[1][a];
      final double w = raw[2][a];
      final double h = raw[3][a];

      final double x1 = (cx - w / 2).clamp(0.0, 1.0);
      final double y1 = (cy - h / 2).clamp(0.0, 1.0);
      final double x2 = (cx + w / 2).clamp(0.0, 1.0);
      final double y2 = (cy + h / 2).clamp(0.0, 1.0);

      candidates.add([x1, y1, x2, y2, bestScore, bestClass.toDouble()]);
    }

    // NMS: نرتب تنازلياً حسب الثقة، ونقصي أي صندوق متداخل بشدة (IoU عالي) مع صندوق أقوى منه
    candidates.sort((a, b) => b[4].compareTo(a[4]));
    const double iouThreshold = 0.45;
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
      if (kept.length >= 300) break; // نفس الحد الأقصى المستخدم بالنماذج end2end
    }

    final detections = <Map<String, dynamic>>[];
    String bestLabel = 'Clear Road';
    double maxScore = 0.0;

    for (final box in kept) {
      final int classId = box[5].round();
      final String label =
          (classId >= 0 && classId < labels.length) ? labels[classId] : 'Class $classId';

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

    return {'label': bestLabel, 'detections': detections};
  }

  static double _iou(List<double> a, List<double> b) {
    final double x1 = a[0] > b[0] ? a[0] : b[0];
    final double y1 = a[1] > b[1] ? a[1] : b[1];
    final double x2 = a[2] < b[2] ? a[2] : b[2];
    final double y2 = a[3] < b[3] ? a[3] : b[3];

    final double interW = (x2 - x1).clamp(0.0, double.infinity);
    final double interH = (y2 - y1).clamp(0.0, double.infinity);
    final double interArea = interW * interH;

    final double areaA = (a[2] - a[0]) * (a[3] - a[1]);
    final double areaB = (b[2] - b[0]) * (b[3] - b[1]);
    final double unionArea = areaA + areaB - interArea;

    return unionArea <= 0 ? 0.0 : interArea / unionArea;
  }
}
