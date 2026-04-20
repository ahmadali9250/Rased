import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';
import 'package:camera/camera.dart';
import 'package:tflite_flutter/tflite_flutter.dart';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:shared_preferences/shared_preferences.dart';

enum AiModelMode { float16, float32 }

class TFLiteService {
  TFLiteService._internal();
  static final TFLiteService _instance = TFLiteService._internal();
  factory TFLiteService() => _instance;

  static const double _minDetectionScore = 0.08;
  static const Duration _inferenceTimeout = Duration(milliseconds: 850);
  static const int _maxConsecutiveIsolateFailures = 3;
  static const String _assetFloat16 = 'assets/best_float16.tflite';
  static const String _assetFloat32 = 'assets/best_float32.tflite';
  static const String _modePrefKey = 'rased_ai_model_mode';
  static AiModelMode _preferredModelMode = AiModelMode.float16;
  static bool _preferredModelModeLoaded = false;

  Interpreter? _interpreter;
  List<String>? _labels;
  String? _activeModelAsset;

  Isolate? _inferenceIsolate;
  ReceivePort? _inferenceReceivePort;
  SendPort? _inferenceSendPort;
  StreamSubscription<dynamic>? _inferenceReceiveSub;
  int _nextRequestId = 0;
  final Map<int, Completer<Map<String, dynamic>>> _pendingIsolateRequests =
      <int, Completer<Map<String, dynamic>>>{};

  Future<void>? _initializationTask;
  bool _isRecoveringInferenceIsolate = false;
  int _consecutiveIsolateFailures = 0;

  int _inputWidth = 0;
  int _inputHeight = 0;

  static String modeLabel(AiModelMode mode) {
    return mode == AiModelMode.float16 ? 'Float16' : 'Float32';
  }

  static String modeShortLabel(AiModelMode mode) {
    return mode == AiModelMode.float16 ? 'F16' : 'F32';
  }

  static String _assetForMode(AiModelMode mode) {
    return mode == AiModelMode.float16 ? _assetFloat16 : _assetFloat32;
  }

  static AiModelMode _modeFromAsset(String? assetPath) {
    if (assetPath == _assetFloat16) return AiModelMode.float16;
    return AiModelMode.float32;
  }

  static String _modeToPref(AiModelMode mode) {
    return mode == AiModelMode.float16 ? 'float16' : 'float32';
  }

  static AiModelMode _modeFromPref(String? prefValue) {
    if (prefValue == 'float16') return AiModelMode.float16;
    return AiModelMode.float32;
  }

  int _threadsForMode(AiModelMode _) {
    // Keep single-thread inference to reduce CPU contention with camera/UI.
    return 1;
  }

  List<String> _orderedCandidateModelAssets(AiModelMode preferredMode) {
    final preferredAsset = _assetForMode(preferredMode);
    final fallbackMode = preferredMode == AiModelMode.float32
        ? AiModelMode.float16
        : AiModelMode.float32;
    return <String>[preferredAsset, _assetForMode(fallbackMode)];
  }

  Future<void> _ensurePreferredModelModeLoaded() async {
    if (_preferredModelModeLoaded) return;

    try {
      final prefs = await SharedPreferences.getInstance();
      _preferredModelMode = _modeFromPref(prefs.getString(_modePrefKey));
    } catch (_) {
      _preferredModelMode = AiModelMode.float16;
    }

    _preferredModelModeLoaded = true;
  }

  Future<void> _savePreferredModelMode(AiModelMode mode) async {
    _preferredModelMode = mode;
    _preferredModelModeLoaded = true;

    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_modePrefKey, _modeToPref(mode));
    } catch (_) {}
  }

  AiModelMode get preferredModelMode => _preferredModelMode;
  AiModelMode get activeModelMode => _modeFromAsset(_activeModelAsset);
  String? get activeModelAsset => _activeModelAsset;

  bool _isLoadedForMode(AiModelMode mode) {
    final targetAsset = _assetForMode(mode);
    return _interpreter != null &&
        _labels != null &&
        _activeModelAsset == targetAsset;
  }

  Future<AiModelMode> switchModelMode(AiModelMode mode) async {
    await _savePreferredModelMode(mode);
    await initializeModel(forceReload: true);
    return activeModelMode;
  }

  void _markIsolateHealthy() {
    _consecutiveIsolateFailures = 0;
  }

  void _markIsolateFailure() {
    _consecutiveIsolateFailures++;
    if (_consecutiveIsolateFailures >= _maxConsecutiveIsolateFailures) {
      _consecutiveIsolateFailures = 0;
      unawaited(_recoverInferenceIsolate());
    }
  }

  Future<void> _recoverInferenceIsolate() async {
    if (_isRecoveringInferenceIsolate) return;
    final assetPath = _activeModelAsset;
    final labels = _labels;
    if (assetPath == null || labels == null || labels.isEmpty) return;

    _isRecoveringInferenceIsolate = true;
    try {
      final modelData = await rootBundle.load(assetPath);
      final modelBytes = modelData.buffer.asUint8List(
        modelData.offsetInBytes,
        modelData.lengthInBytes,
      );

      await _startPersistentInferenceIsolate(
        modelBytes,
        labels,
        _modeFromAsset(assetPath),
      );
    } catch (_) {
      _stopInferenceIsolate();
    } finally {
      _isRecoveringInferenceIsolate = false;
    }
  }

  Future<void> initializeModel({bool forceReload = false}) async {
    await _ensurePreferredModelModeLoaded();

    final desiredMode = _preferredModelMode;

    if (!forceReload && _isLoadedForMode(desiredMode)) {
      return;
    }

    if (_initializationTask != null) {
      await _initializationTask!;
      return;
    }

    final task = _initializeModelInternal(desiredMode);
    _initializationTask = task;

    try {
      await task;
    } finally {
      if (identical(_initializationTask, task)) {
        _initializationTask = null;
      }
    }
  }

  Future<void> _initializeModelInternal(AiModelMode desiredMode) async {
    try {
      _stopInferenceIsolate();

      _interpreter?.close();
      _interpreter = null;
      _labels = null;
      _activeModelAsset = null;
      _inputWidth = 0;
      _inputHeight = 0;
      _consecutiveIsolateFailures = 0;
      _isRecoveringInferenceIsolate = false;

      final candidateAssets = _orderedCandidateModelAssets(desiredMode);
      for (final assetPath in candidateAssets) {
        try {
          const fallbackThreads = 1;
          final cpuOptions = InterpreterOptions()
            ..threads = fallbackThreads
            ..useNnApiForAndroid = false;
          final candidate = await Interpreter.fromAsset(
            assetPath,
            options: cpuOptions,
          );

          _interpreter = candidate;
          _activeModelAsset = assetPath;
          break;
        } catch (_) {
          continue;
        }
      }

      if (_interpreter == null || _activeModelAsset == null) {
        throw Exception('No usable TFLite model asset found.');
      }
      debugPrint('✅ AI Model loaded successfully: $_activeModelAsset');

      // Make tensor allocation explicit so delegate state is stable before warm-up/inference.
      _interpreter!.allocateTensors();

      final labelFile = await rootBundle.loadString('assets/classes.txt');
      _labels = labelFile
          .split('\n')
          .where((label) => label.trim().isNotEmpty)
          .toList();

      final inputShape = _interpreter!.getInputTensor(0).shape;
      _inputHeight = inputShape[1];
      _inputWidth = inputShape[2];

      try {
        final modelData = await rootBundle.load(_activeModelAsset!);
        final modelBytes = modelData.buffer.asUint8List(
          modelData.offsetInBytes,
          modelData.lengthInBytes,
        );

        await _startPersistentInferenceIsolate(
          modelBytes,
          _labels ?? <String>[],
          _modeFromAsset(_activeModelAsset),
        );
      } catch (e) {
        // Keep local interpreter active so detection still works if isolate path is unavailable.
        _stopInferenceIsolate();
        debugPrint(
          '⚠️ Isolate inference unavailable, using local fallback: $e',
        );
      }

      // Skip startup warm-up to avoid long first-screen freezes on lower-end devices.
    } catch (e) {
      debugPrint('❌ Error loading AI model: $e');
    }
  }

  Map<String, dynamic> _emptyDetectionResult() {
    return {'label': 'Clear Road', 'detections': <Map<String, dynamic>>[]};
  }

  Future<void> _startPersistentInferenceIsolate(
    Uint8List modelBytes,
    List<String> labels,
    AiModelMode mode,
  ) async {
    _stopInferenceIsolate();

    final readyCompleter = Completer<void>();
    _inferenceReceivePort = ReceivePort();
    _inferenceReceiveSub = _inferenceReceivePort!.listen((dynamic message) {
      if (message is SendPort) {
        _inferenceSendPort = message;
        return;
      }

      if (message is! Map) return;
      final type = message['type'];

      if (type == 'ready') {
        if (!readyCompleter.isCompleted) {
          readyCompleter.complete();
        }
        return;
      }

      if (type == 'fatal') {
        final error = message['error']?.toString() ?? 'Unknown isolate error';
        if (!readyCompleter.isCompleted) {
          readyCompleter.completeError(Exception(error));
        }
        return;
      }

      final requestId = message['id'];
      if (requestId is! int) return;

      final completer = _pendingIsolateRequests.remove(requestId);
      if (completer == null || completer.isCompleted) return;

      if (type == 'result') {
        final payload = message['payload'];
        if (payload is Map) {
          completer.complete(Map<String, dynamic>.from(payload));
        } else {
          completer.complete(_emptyDetectionResult());
        }
      } else {
        completer.complete(_emptyDetectionResult());
      }
    });

    _inferenceIsolate = await Isolate.spawn<Map<String, dynamic>>(
      _persistentInferenceIsolateEntry,
      {
        'mainSendPort': _inferenceReceivePort!.sendPort,
        'modelBytes': modelBytes,
        'labels': labels,
        'threads': _threadsForMode(mode),
      },
      debugName: 'rased_tflite_inference',
    );

    await readyCompleter.future.timeout(const Duration(seconds: 6));
  }

  void _stopInferenceIsolate() {
    try {
      _inferenceSendPort?.send({'type': 'dispose'});
    } catch (_) {}

    _inferenceIsolate?.kill(priority: Isolate.immediate);
    _inferenceIsolate = null;
    _inferenceSendPort = null;

    final sub = _inferenceReceiveSub;
    _inferenceReceiveSub = null;
    if (sub != null) {
      unawaited(sub.cancel());
    }

    _inferenceReceivePort?.close();
    _inferenceReceivePort = null;

    if (_pendingIsolateRequests.isNotEmpty) {
      final fallback = _emptyDetectionResult();
      for (final completer in _pendingIsolateRequests.values) {
        if (!completer.isCompleted) {
          completer.complete(fallback);
        }
      }
      _pendingIsolateRequests.clear();
    }
  }

  Map<String, dynamic>? _serializeCameraImage(CameraImage cameraImage) {
    final formatGroup = cameraImage.format.group;

    if (formatGroup == ImageFormatGroup.yuv420) {
      if (cameraImage.planes.length < 3) return null;
      final yPlane = cameraImage.planes[0];
      final uPlane = cameraImage.planes[1];
      final vPlane = cameraImage.planes[2];
      final uvPixelStride = uPlane.bytesPerPixel ?? 0;
      if (uvPixelStride == 0) return null;

      return {
        'format': 'yuv420',
        'width': cameraImage.width,
        'height': cameraImage.height,
        'plane0': TransferableTypedData.fromList([yPlane.bytes]),
        'plane1': TransferableTypedData.fromList([uPlane.bytes]),
        'plane2': TransferableTypedData.fromList([vPlane.bytes]),
        'yRowStride': yPlane.bytesPerRow,
        'uvRowStride': uPlane.bytesPerRow,
        'uvPixelStride': uvPixelStride,
      };
    }

    if (formatGroup == ImageFormatGroup.bgra8888) {
      if (cameraImage.planes.isEmpty) return null;
      final plane = cameraImage.planes[0];
      return {
        'format': 'bgra8888',
        'width': cameraImage.width,
        'height': cameraImage.height,
        'plane0': TransferableTypedData.fromList([plane.bytes]),
      };
    }

    return null;
  }

  Future<Map<String, dynamic>> _predictFrameWithBoxesViaIsolate(
    CameraImage cameraImage,
  ) async {
    final sendPort = _inferenceSendPort;
    if (sendPort == null) {
      return {
        'label': 'Clear Road',
        'detections': <Map<String, dynamic>>[],
        '_inferenceError': 'isolate_not_ready',
      };
    }

    final framePayload = _serializeCameraImage(cameraImage);
    if (framePayload == null) {
      return {
        'label': 'Clear Road',
        'detections': <Map<String, dynamic>>[],
        '_inferenceError': 'frame_serialize_failed',
      };
    }

    final requestId = _nextRequestId++;
    final completer = Completer<Map<String, dynamic>>();
    _pendingIsolateRequests[requestId] = completer;

    sendPort.send({'type': 'infer', 'id': requestId, 'frame': framePayload});

    try {
      return await completer.future.timeout(
        _inferenceTimeout,
        onTimeout: () {
          _pendingIsolateRequests.remove(requestId);
          return {
            'label': 'Clear Road',
            'detections': <Map<String, dynamic>>[],
            '_inferenceError': 'isolate_timeout',
          };
        },
      );
    } catch (_) {
      _pendingIsolateRequests.remove(requestId);
      return {
        'label': 'Clear Road',
        'detections': <Map<String, dynamic>>[],
        '_inferenceError': 'isolate_exception',
      };
    }
  }

  // ignore: unused_element
  void _warmUpInterpreter() {
    if (_interpreter == null || _labels == null) return;
    try {
      final black = img.Image(width: _inputWidth, height: _inputHeight);
      _runInterpreter(black, _interpreter!, _labels!);
      debugPrint('✅ AI warm-up completed ($_inputWidth x $_inputHeight)');
    } catch (e) {
      debugPrint('⚠️ AI warm-up skipped: $e');
    }
  }

  void dispose() {
    _initializationTask = null;
    _stopInferenceIsolate();
    _interpreter?.close();
    _interpreter = null;
    _labels = null;
    _activeModelAsset = null;
    _inputWidth = 0;
    _inputHeight = 0;
  }

  // --- MANUAL MODE (Still runs normally) ---
  Future<String> predictImage(String imagePath) async {
    if (_interpreter == null || _labels == null) return "Clear Road";
    try {
      File file = File(imagePath);
      final imageData = file.readAsBytesSync();
      img.Image? image = img.decodeImage(imageData);
      if (image == null) return "Clear Road";

      return _runInterpreter(image, _interpreter!, _labels!);
    } catch (e) {
      return "Clear Road";
    }
  }

  // --- HIGH-SPEED DASHCAM MODE ---
  Future<String> predictFrame(CameraImage cameraImage) async {
    if (_interpreter == null || _labels == null) return "Clear Road";

    try {
      final image = _cameraImageToImage(cameraImage);
      if (image == null) return "Clear Road";
      return _runInterpreter(image, _interpreter!, _labels!);
    } catch (e) {
      debugPrint('❌ Error during frame prediction: $e');
      return "Clear Road";
    }
  }

  // ==========================================
  // CORE YOLO11 MATH EXECUTION
  // ==========================================
  static String _runInterpreter(
    img.Image image,
    Interpreter interpreter,
    List<String> labels,
  ) {
    var inputShape = interpreter.getInputTensor(0).shape;
    int inputHeight = inputShape[1];
    int inputWidth = inputShape[2];

    img.Image resizedImage = img.copyResize(
      image,
      width: inputWidth,
      height: inputHeight,
    );

    var inputBuffer = List.generate(
      1,
      (i) => List.generate(
        inputHeight,
        (y) => List.generate(inputWidth, (x) {
          final pixel = resizedImage.getPixel(x, y);
          return [pixel.r / 255.0, pixel.g / 255.0, pixel.b / 255.0];
        }),
      ),
    );

    var outputShape = interpreter.getOutputTensor(0).shape;
    Object outputBuffer;

    if (outputShape.length == 3) {
      outputBuffer = List.generate(
        outputShape[0],
        (i) => List.generate(
          outputShape[1],
          (j) => List.filled(outputShape[2], 0.0),
        ),
      );
    } else {
      outputBuffer = List.generate(
        outputShape[0],
        (i) => List.filled(outputShape[1], 0.0),
      );
    }

    interpreter.run(inputBuffer, outputBuffer);

    double maxScore = 0.0;
    String bestLabel = "Clear Road";

    if (outputShape.length == 3) {
      var parsedOutput = outputBuffer as List<List<List<double>>>;
      int numBoxes = outputShape[2];
      int numChannels = outputShape[1];
      final int classCount = labels.length;
      final bool hasObjectness = (numChannels - 5) == classCount;
      final int classStartIndex = hasObjectness ? 5 : 4;

      for (int i = 0; i < numBoxes; i++) {
        double score = 0.0;
        String label = labels.isNotEmpty ? labels.first : "Unknown";

        if (numChannels > classStartIndex) {
          int bestClassIndex = 0;
          double bestClassProb = 0.0;
          for (int c = classStartIndex; c < numChannels; c++) {
            double classProb = parsedOutput[0][c][i];
            if (classProb > bestClassProb) {
              bestClassProb = classProb;
              bestClassIndex = c - classStartIndex;
            }
          }
          final objectness = hasObjectness ? parsedOutput[0][4][i] : 1.0;
          score = objectness * bestClassProb;
          if (labels.isNotEmpty && bestClassIndex < labels.length) {
            label = labels[bestClassIndex];
          } else {
            label = "Class $bestClassIndex";
          }
        } else {
          continue;
        }

        if (score > maxScore) {
          maxScore = score;
          bestLabel = label;
        }
      }
    } else if (outputShape.length == 2) {
      var parsedOutput = outputBuffer as List<List<double>>;
      maxScore = parsedOutput[0][0];
      bestLabel = labels.isNotEmpty ? labels.first : "Pothole";
    }

    if (maxScore > _minDetectionScore) {
      return bestLabel;
    } else {
      return "Clear Road";
    }
  }

  Future<Map<String, dynamic>> predictFrameWithBoxes(
    CameraImage cameraImage,
  ) async {
    if (_inferenceSendPort == null) {
      _markIsolateFailure();
      return _emptyDetectionResult();
    }

    final isolateResult = await _predictFrameWithBoxesViaIsolate(cameraImage);
    final hasError = isolateResult['_inferenceError'] != null;
    if (!hasError) {
      _markIsolateHealthy();
      return isolateResult;
    }

    _markIsolateFailure();
    return _emptyDetectionResult();
  }

  img.Image? _cameraImageToImage(CameraImage cameraImage) {
    final format = cameraImage.format.group == ImageFormatGroup.yuv420
        ? 'yuv420'
        : 'bgra8888';
    final width = cameraImage.width;
    final height = cameraImage.height;

    if (format == 'yuv420') {
      if (cameraImage.planes.length < 3) return null;
      final plane0 = cameraImage.planes[0].bytes;
      final plane1 = cameraImage.planes[1].bytes;
      final plane2 = cameraImage.planes[2].bytes;
      final yRowStride = cameraImage.planes[0].bytesPerRow;
      final uvRowStride = cameraImage.planes[1].bytesPerRow;
      final uvPixelStride = cameraImage.planes[1].bytesPerPixel ?? 0;
      if (uvPixelStride == 0) return null;

      final image = img.Image(width: width, height: height);
      for (int y = 0; y < height; y++) {
        final yRow = y * yRowStride;
        final uvRow = uvRowStride * (y ~/ 2);
        for (int x = 0; x < width; x++) {
          final uvIndex = uvPixelStride * (x ~/ 2) + uvRow;
          final index = yRow + x;

          final yp = plane0[index];
          final up = plane1[uvIndex];
          final vp = plane2[uvIndex];

          final r = (yp + vp * 1436 / 1024 - 179).round().clamp(0, 255);
          final g = (yp - up * 46549 / 131072 + 44 - vp * 93604 / 131072 + 91)
              .round()
              .clamp(0, 255);
          final b = (yp + up * 1814 / 1024 - 227).round().clamp(0, 255);

          image.setPixelRgb(x, y, r, g, b);
        }
      }
      return image;
    }

    if (format == 'bgra8888') {
      final plane0 = cameraImage.planes[0].bytes;
      return img.Image.fromBytes(
        width: width,
        height: height,
        bytes: plane0.buffer,
        order: img.ChannelOrder.bgra,
      );
    }

    return null;
  }

  @pragma('vm:entry-point')
  static void _persistentInferenceIsolateEntry(Map<String, dynamic> args) {
    final mainSendPort = args['mainSendPort'] as SendPort;
    final workerReceivePort = ReceivePort();
    mainSendPort.send(workerReceivePort.sendPort);

    Interpreter? interpreter;
    List<String> labels = const <String>[];

    try {
      final modelBytes = args['modelBytes'] as Uint8List;
      final requestedThreads = (args['threads'] as int?) ?? 2;
      final threadCount = requestedThreads < 1 ? 1 : requestedThreads;
      labels = (args['labels'] as List<dynamic>)
          .map((dynamic e) => e.toString())
          .toList();

      final cpuOptions = InterpreterOptions()
        ..threads = threadCount
        ..useNnApiForAndroid = false;
      interpreter = Interpreter.fromBuffer(modelBytes, options: cpuOptions);
      interpreter.allocateTensors();

      mainSendPort.send({'type': 'ready'});
    } catch (e) {
      mainSendPort.send({'type': 'fatal', 'error': '$e'});
      workerReceivePort.close();
      return;
    }

    workerReceivePort.listen((dynamic message) {
      if (message is! Map) return;

      final type = message['type'];
      if (type == 'dispose') {
        workerReceivePort.close();
        interpreter?.close();
        Isolate.exit();
      }

      if (type != 'infer') return;
      final id = message['id'];
      if (id is! int) return;

      try {
        final framePayload = message['frame'];
        if (framePayload is! Map) {
          mainSendPort.send({
            'type': 'result',
            'id': id,
            'payload': {
              'label': 'Clear Road',
              'detections': <Map<String, dynamic>>[],
            },
          });
          return;
        }

        final image = _payloadToImage(Map<String, dynamic>.from(framePayload));
        if (image == null || interpreter == null) {
          mainSendPort.send({
            'type': 'result',
            'id': id,
            'payload': {
              'label': 'Clear Road',
              'detections': <Map<String, dynamic>>[],
            },
          });
          return;
        }

        final result = _runInterpreterWithBoxesStatic(
          image,
          interpreter,
          labels,
        );
        mainSendPort.send({'type': 'result', 'id': id, 'payload': result});
      } catch (e) {
        mainSendPort.send({'type': 'error', 'id': id, 'error': '$e'});
      }
    });
  }

  static Uint8List? _materializePlane(dynamic planeData) {
    if (planeData is TransferableTypedData) {
      final bytes = planeData.materialize().asUint8List();
      return bytes;
    }
    if (planeData is Uint8List) return planeData;
    if (planeData is ByteBuffer) return planeData.asUint8List();
    return null;
  }

  static img.Image? _payloadToImage(Map<String, dynamic> payload) {
    final format = payload['format']?.toString() ?? '';
    final width = payload['width'] as int?;
    final height = payload['height'] as int?;
    if (width == null || height == null) return null;

    if (format == 'yuv420') {
      final plane0 = _materializePlane(payload['plane0']);
      final plane1 = _materializePlane(payload['plane1']);
      final plane2 = _materializePlane(payload['plane2']);
      final yRowStride = payload['yRowStride'] as int?;
      final uvRowStride = payload['uvRowStride'] as int?;
      final uvPixelStride = payload['uvPixelStride'] as int?;

      if (plane0 == null ||
          plane1 == null ||
          plane2 == null ||
          yRowStride == null ||
          uvRowStride == null ||
          uvPixelStride == null ||
          uvPixelStride == 0) {
        return null;
      }

      final image = img.Image(width: width, height: height);
      for (int y = 0; y < height; y++) {
        final yRow = y * yRowStride;
        final uvRow = uvRowStride * (y ~/ 2);
        for (int x = 0; x < width; x++) {
          final uvIndex = uvPixelStride * (x ~/ 2) + uvRow;
          final index = yRow + x;

          final yp = plane0[index];
          final up = plane1[uvIndex];
          final vp = plane2[uvIndex];

          final r = (yp + vp * 1436 / 1024 - 179).round().clamp(0, 255);
          final g = (yp - up * 46549 / 131072 + 44 - vp * 93604 / 131072 + 91)
              .round()
              .clamp(0, 255);
          final b = (yp + up * 1814 / 1024 - 227).round().clamp(0, 255);

          image.setPixelRgb(x, y, r, g, b);
        }
      }
      return image;
    }

    if (format == 'bgra8888') {
      final plane0 = _materializePlane(payload['plane0']);
      if (plane0 == null) return null;
      return img.Image.fromBytes(
        width: width,
        height: height,
        bytes: plane0.buffer,
        order: img.ChannelOrder.bgra,
      );
    }

    return null;
  }

  static Map<String, dynamic> _runInterpreterWithBoxesStatic(
    img.Image image,
    Interpreter interpreter,
    List<String> labels,
  ) {
    try {
      final inputShape = interpreter.getInputTensor(0).shape;
      final inputH = inputShape[1];
      final inputW = inputShape[2];
      final resized = img.copyResize(image, width: inputW, height: inputH);

      final inputBuffer = List.generate(
        1,
        (_) => List.generate(
          inputH,
          (y) => List.generate(inputW, (x) {
            final pixel = resized.getPixel(x, y);
            return [pixel.r / 255.0, pixel.g / 255.0, pixel.b / 255.0];
          }),
        ),
      );

      final outputShape = interpreter.getOutputTensor(0).shape;
      if (outputShape.length != 3) {
        return {'label': 'Clear Road', 'detections': <Map<String, dynamic>>[]};
      }

      final outputBuffer = List.generate(
        outputShape[0],
        (_) => List.generate(
          outputShape[1],
          (_) => List.filled(outputShape[2], 0.0),
        ),
      );

      interpreter.run(inputBuffer, outputBuffer);

      final parsed = outputBuffer;
      final dim1 = outputShape[1];
      final dim2 = outputShape[2];
      final layout = _resolveYoloLayout(dim1, dim2, labels.length);
      final channelsOnDim1 = layout['channelsOnDim1'] as bool;
      final numChannels = channelsOnDim1 ? dim1 : dim2;
      final numBoxes = channelsOnDim1 ? dim2 : dim1;

      double val(int channel, int box) {
        return channelsOnDim1
            ? parsed[0][channel][box]
            : parsed[0][box][channel];
      }

      final classCount = labels.length;
      final hasObjectness = (numChannels - 5) == classCount;
      final classStartIndex = hasObjectness ? 5 : 4;

      final detections = <Map<String, dynamic>>[];
      var bestLabel = 'Clear Road';
      var maxScore = 0.0;

      for (int i = 0; i < numBoxes; i++) {
        if (numChannels <= classStartIndex) continue;

        var bestClassIndex = 0;
        var bestClassProb = 0.0;
        for (int c = classStartIndex; c < numChannels; c++) {
          final classProb = val(c, i);
          if (classProb > bestClassProb) {
            bestClassProb = classProb;
            bestClassIndex = c - classStartIndex;
          }
        }

        final objectness = hasObjectness ? val(4, i) : 1.0;
        final score = objectness * bestClassProb;
        if (score <= _minDetectionScore) continue;

        final label = (labels.isNotEmpty && bestClassIndex < labels.length)
            ? labels[bestClassIndex]
            : 'Class $bestClassIndex';

        double cx = val(0, i);
        double cy = val(1, i);
        double w = val(2, i);
        double h = val(3, i);

        if (cx > 2.0 || cy > 2.0) {
          cx /= inputW;
          cy /= inputH;
          w /= inputW;
          h /= inputH;
        }

        detections.add({
          'x1': (cx - w / 2).clamp(0.0, 1.0),
          'y1': (cy - h / 2).clamp(0.0, 1.0),
          'x2': (cx + w / 2).clamp(0.0, 1.0),
          'y2': (cy + h / 2).clamp(0.0, 1.0),
          'conf': score,
          'label': label,
        });

        if (score > maxScore) {
          maxScore = score;
          bestLabel = label;
        }
      }

      final nms = _nonMaxSuppression(detections, iouThreshold: 0.45);
      if (nms.isNotEmpty) {
        final top = nms.first;
        bestLabel = (top['label'] as String?) ?? bestLabel;
      }

      return {'label': bestLabel, 'detections': nms};
    } catch (_) {
      return {'label': 'Clear Road', 'detections': <Map<String, dynamic>>[]};
    }
  }

  static Map<String, dynamic> _resolveYoloLayout(
    int dim1,
    int dim2,
    int classCount,
  ) {
    final dim1LooksLikeChannels =
        dim1 == classCount + 4 || dim1 == classCount + 5;
    final dim2LooksLikeChannels =
        dim2 == classCount + 4 || dim2 == classCount + 5;

    if (dim1LooksLikeChannels && !dim2LooksLikeChannels) {
      return {'channelsOnDim1': true};
    }
    if (dim2LooksLikeChannels && !dim1LooksLikeChannels) {
      return {'channelsOnDim1': false};
    }

    // Heuristic fallback: channel count is usually much smaller than box count.
    if (dim1 <= 256 && dim2 > dim1) {
      return {'channelsOnDim1': true};
    }
    if (dim2 <= 256 && dim1 > dim2) {
      return {'channelsOnDim1': false};
    }

    return {'channelsOnDim1': true};
  }

  static List<Map<String, dynamic>> _nonMaxSuppression(
    List<Map<String, dynamic>> detections, {
    required double iouThreshold,
  }) {
    if (detections.length <= 1) return detections;

    final sorted = [...detections]
      ..sort((a, b) => (b['conf'] as double).compareTo(a['conf'] as double));

    final kept = <Map<String, dynamic>>[];

    while (sorted.isNotEmpty) {
      final current = sorted.removeAt(0);
      kept.add(current);

      sorted.removeWhere((candidate) {
        if ((candidate['label'] ?? '') != (current['label'] ?? '')) {
          return false;
        }
        return _iou(current, candidate) >= iouThreshold;
      });
    }

    return kept;
  }

  static double _iou(Map<String, dynamic> a, Map<String, dynamic> b) {
    final ax1 = (a['x1'] as double);
    final ay1 = (a['y1'] as double);
    final ax2 = (a['x2'] as double);
    final ay2 = (a['y2'] as double);

    final bx1 = (b['x1'] as double);
    final by1 = (b['y1'] as double);
    final bx2 = (b['x2'] as double);
    final by2 = (b['y2'] as double);

    final intersectionLeft = ax1 > bx1 ? ax1 : bx1;
    final intersectionTop = ay1 > by1 ? ay1 : by1;
    final intersectionRight = ax2 < bx2 ? ax2 : bx2;
    final intersectionBottom = ay2 < by2 ? ay2 : by2;

    final intersectionWidth = (intersectionRight - intersectionLeft).clamp(
      0.0,
      1.0,
    );
    final intersectionHeight = (intersectionBottom - intersectionTop).clamp(
      0.0,
      1.0,
    );
    final intersectionArea = intersectionWidth * intersectionHeight;

    final areaA = (ax2 - ax1).clamp(0.0, 1.0) * (ay2 - ay1).clamp(0.0, 1.0);
    final areaB = (bx2 - bx1).clamp(0.0, 1.0) * (by2 - by1).clamp(0.0, 1.0);
    final unionArea = areaA + areaB - intersectionArea;

    if (unionArea <= 0) return 0.0;
    return intersectionArea / unionArea;
  }
}
