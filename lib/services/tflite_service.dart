import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'detection_worker.dart';

/// Main-isolate facade over the background [detectionWorkerMain] isolate.
///
/// This class does no pixel work and never blocks the UI thread. It:
///  * loads the model bytes and labels once and spawns the worker;
///  * forwards camera frames (at most one in flight — see [sendFrame]);
///  * delivers results through [onResult];
///  * answers one-off requests (report snapshot, still-image prediction).
///
/// It is a singleton: the live camera screen and the manual report screen
/// share the same warm worker, and nothing disposes it on screen exit, so
/// re-entering the camera has zero warm-up.
class TFLiteService {
  TFLiteService._();

  static final TFLiteService instance = TFLiteService._();

  /// Current model asset. Naming convention: `pothole_<arch>_<imgsz>_<prec>`.
  /// Keep this list in sync with `pubspec.yaml` → `flutter: assets:`.
  static const String defaultModelAsset =
      'assets/pothole_yolo26n_640_fp32.tflite';

  /// Candidates for the on-device bench harness (long-press the AI panel in
  /// the live screen). Add exported variants here *and* in `pubspec.yaml`
  /// while benchmarking; ship with only the winner.
  static const List<String> benchModelAssets = <String>[
    defaultModelAsset,
    // 'assets/pothole_yolo26n_416_fp32.tflite',
    // 'assets/pothole_yolo26n_416_fp32_raw.tflite',
    // 'assets/pothole_yolo26n_320_fp32_raw.tflite',
    // 'assets/pothole_yolo26n_416_int8_raw.tflite',
  ];

  static const String labelsAsset = 'assets/classes.txt';

  /// Deliberately low while field-testing: the screen applies its own
  /// UI/report thresholds on top and requires several consecutive frames.
  static const double confThreshold = 0.20;
  static const double iouThreshold = 0.45;

  // --- runtime configuration (changed via [restart]) ---
  String modelAsset = defaultModelAsset;
  bool preferGpu = true;

  /// NNAPI is deprecated from Android 15 and fails per-vendor in the slow
  /// "accepted at create, rejected at invoke" way. Off by default; keep it for
  /// int8 experiments only.
  bool allowNnapi = false;
  int gpuMaxPartitions = 4;

  /// CPU path: let XNNPACK run FP32 ops in FP16 arithmetic (ARMv8.2+).
  /// Roughly 1.3–1.8× faster on mid-range phones; same trade as the GPU path.
  bool cpuFp16 = true;

  // --- isolate plumbing ---
  Isolate? _isolate;
  SendPort? _workerPort;
  ReceivePort? _receivePort;
  ReceivePort? _errorPort;
  ReceivePort? _exitPort;
  Future<void>? _initFuture;
  Completer<void>? _readyCompleter;
  int _generation = 0;

  WorkerReady? _info;
  String? _startupError;
  List<String> _labels = const <String>[];
  int _rotationDegrees = 0;

  // --- request tracking ---
  int _nextId = 1;
  bool _frameInFlight = false;
  final Map<int, Completer<Object>> _pending = <int, Completer<Object>>{};

  /// Live detection results. Set by the camera screen; called on the main
  /// isolate, once per processed frame, in order.
  void Function(DetectionResult result)? onResult;

  final ValueNotifier<List<String>> _diagnosticEvents =
      ValueNotifier<List<String>>(const <String>['AI | Waiting to initialise…']);

  // ===========================================================================
  // Public state
  // ===========================================================================

  bool get isReady =>
      _startupError == null && _info != null && _workerPort != null;
  bool get isFrameInFlight => _frameInFlight;
  String? get diagnosticError => _startupError;
  String get activeBackend => _info?.backend ?? 'unknown';
  WorkerReady? get modelInfo => _info;
  List<String> get labels => _labels;
  ValueListenable<List<String>> get diagnosticEvents => _diagnosticEvents;

  // ===========================================================================
  // Lifecycle
  // ===========================================================================

  /// Idempotent. Safe to call from `main()` (not awaited) to pre-warm the
  /// worker, and again from any screen that needs the model.
  Future<void> initialize() => _initFuture ??= _spawn();

  /// Tear the worker down and start again with the current configuration.
  /// Used by the bench harness to switch model / backend at runtime.
  Future<void> restart({String? modelAsset, bool? preferGpu}) async {
    if (modelAsset != null) this.modelAsset = modelAsset;
    if (preferGpu != null) this.preferGpu = preferGpu;
    await _shutdownWorker();
    _initFuture = null;
    await initialize();
  }

  /// Only for full app teardown. Screens must NOT call this.
  Future<void> dispose() async {
    await _shutdownWorker();
    _initFuture = null;
  }

  Future<void> _spawn() async {
    final generation = ++_generation;
    _startupError = null;
    _info = null;
    _frameInFlight = false;
    _addEvent('AI | Loading $modelAsset…');

    final ByteData modelData;
    try {
      modelData = await rootBundle.load(modelAsset);
    } catch (e) {
      _fail('Model asset not found: $modelAsset ($e)');
      return;
    }
    try {
      final labelFile = await rootBundle.loadString(labelsAsset);
      _labels = List<String>.unmodifiable(
        labelFile
            .split('\n')
            .map((l) => l.trim())
            .where((l) => l.isNotEmpty),
      );
    } catch (e) {
      _fail('Could not load $labelsAsset ($e)');
      return;
    }
    if (_labels.isEmpty) {
      _fail('$labelsAsset is empty; YOLO labels are required.');
      return;
    }
    if (generation != _generation) return; // restarted meanwhile

    final receivePort = ReceivePort();
    final errorPort = ReceivePort();
    final exitPort = ReceivePort();
    final ready = Completer<void>();
    _receivePort = receivePort;
    _errorPort = errorPort;
    _exitPort = exitPort;
    _readyCompleter = ready;

    receivePort.listen((Object? message) => _onWorkerMessage(message));
    errorPort.listen((Object? error) {
      final text = error is List && error.isNotEmpty
          ? '${error.first}'
          : '$error';
      debugPrint('❌ AI worker uncaught error: $text');
      _addEvent('AI | WORKER ERROR | ${_short(text)}');
      _failPending(StateError('Detection worker error: $text'));
      _frameInFlight = false;
    });
    exitPort.listen((_) {
      if (generation != _generation) return;
      debugPrint('⚠️ AI worker exited');
      _workerPort = null;
      _info = null;
      _startupError ??= 'Detection worker exited unexpectedly.';
      _failPending(StateError(_startupError!));
      _frameInFlight = false;
      if (!ready.isCompleted) ready.complete();
    });

    final cores = Platform.numberOfProcessors;
    final bytes = modelData.buffer.asUint8List(
      modelData.offsetInBytes,
      modelData.lengthInBytes,
    );
    try {
      _isolate = await Isolate.spawn<WorkerInit>(
        detectionWorkerMain,
        WorkerInit(
          mainPort: receivePort.sendPort,
          // Moves the ~10 MB model into the worker instead of copying it.
          modelBytes: TransferableTypedData.fromList(<Uint8List>[bytes]),
          labels: _labels,
          confThreshold: confThreshold,
          iouThreshold: iouThreshold,
          preferGpu: preferGpu,
          allowNnapi: allowNnapi,
          cpuThreads: cores > 4 ? 4 : (cores < 1 ? 1 : cores),
          gpuMaxPartitions: gpuMaxPartitions,
          rotationDegrees: _rotationDegrees,
          allowCpuFp16: cpuFp16,
        ),
        onError: errorPort.sendPort,
        onExit: exitPort.sendPort,
        debugName: 'pothole-detection-worker',
      );
    } catch (e) {
      _fail('Could not spawn detection worker: $e');
      return;
    }

    await ready.future;
    if (_startupError == null && _info != null) {
      final info = _info!;
      debugPrint(
        '✅ AI worker ready | ${info.backend} | input ${info.inputWidth}x'
        '${info.inputHeight} ${info.channelsFirst ? 'NCHW' : 'NHWC'} '
        '${info.inputType} | output ${info.outputShape} ${info.outputLayout} '
        '| warm-up ${info.warmupMs} ms',
      );
      _addEvent(
        'AI | Ready | ${info.backend} | ${info.inputWidth}x${info.inputHeight} '
        '| ${info.outputLayout} | warm-up ${info.warmupMs} ms',
      );
    }
  }

  void _onWorkerMessage(Object? message) {
    if (message is WorkerReady) {
      _workerPort = message.port;
      _info = message;
      _startupError = null;
      final ready = _readyCompleter;
      if (ready != null && !ready.isCompleted) ready.complete();
    } else if (message is WorkerFatal) {
      _fail(message.message);
    } else if (message is WorkerEvent) {
      if (message.isError) {
        debugPrint('⚠️ ${message.message}');
      } else {
        debugPrint('ℹ️ ${message.message}');
      }
      _addEvent(message.message);
    } else if (message is ResultMsg) {
      final completer = _pending.remove(message.id);
      if (completer != null) {
        completer.complete(message);
        return;
      }
      // Live frame. Clear the busy flag BEFORE the callback so the screen can
      // dispatch the next frame immediately from inside it.
      _frameInFlight = false;
      final callback = onResult;
      if (callback != null) {
        callback(DetectionResult._(message, _labels));
      }
    } else if (message is SnapshotResult) {
      _pending.remove(message.id)?.complete(message);
    }
  }

  void _fail(String error) {
    _startupError = error;
    debugPrint('❌ $error');
    _addEvent('AI | STARTUP ERROR | ${_short(error)}');
    final ready = _readyCompleter;
    if (ready != null && !ready.isCompleted) ready.complete();
    _failPending(StateError(error));
  }

  void _failPending(Object error) {
    final pending = List<Completer<Object>>.from(_pending.values);
    _pending.clear();
    for (final c in pending) {
      if (!c.isCompleted) c.completeError(error);
    }
  }

  Future<void> _shutdownWorker() async {
    _generation++;
    final port = _workerPort;
    final isolate = _isolate;
    _workerPort = null;
    _info = null;
    _frameInFlight = false;
    _failPending(StateError('Detection worker restarting'));

    if (port != null) {
      port.send(const CloseMsg());
      // Give the worker a moment to free the interpreter/delegate cleanly.
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
    isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    _receivePort?.close();
    _errorPort?.close();
    _exitPort?.close();
    _receivePort = null;
    _errorPort = null;
    _exitPort = null;
    // Release anyone still awaiting the previous initialize().
    final ready = _readyCompleter;
    if (ready != null && !ready.isCompleted) ready.complete();
    _readyCompleter = null;
  }

  // ===========================================================================
  // Requests
  // ===========================================================================

  /// Clockwise rotation (0/90/180/270) that makes a raw camera frame upright.
  /// Applied inside the worker when sampling, so the model sees the road the
  /// way it was trained, and the report JPEG is upright too.
  void setRotation(int degrees) {
    final normalized = ((degrees % 360) + 360) % 360;
    if (normalized == _rotationDegrees) return;
    _rotationDegrees = normalized;
    _workerPort?.send(SetRotationMsg(normalized));
  }

  int get rotationDegrees => _rotationDegrees;

  /// Forwards one camera frame. Returns `false` (and does nothing) if the
  /// worker is not ready or a frame is already being processed — the caller
  /// keeps the newest frame and re-sends it from [onResult].
  bool sendFrame(CameraImage image) {
    final port = _workerPort;
    if (port == null || !isReady || _frameInFlight) return false;

    final planes = image.planes;
    if (planes.isEmpty) return false;
    final int format;
    switch (image.format.group) {
      case ImageFormatGroup.yuv420:
        if (planes.length < 3) return false;
        format = FrameFormat.yuv420;
      case ImageFormatGroup.bgra8888:
        format = FrameFormat.bgra8888;
      default:
        return false;
    }

    _frameInFlight = true;
    port.send(
      FrameMsg(
        id: _nextId++,
        width: image.width,
        height: image.height,
        format: format,
        plane0: planes[0].bytes,
        rowStride0: planes[0].bytesPerRow,
        plane1: planes.length > 1 ? planes[1].bytes : null,
        plane2: planes.length > 2 ? planes[2].bytes : null,
        rowStride1: planes.length > 1 ? planes[1].bytesPerRow : 0,
        pixelStride1: planes.length > 1 ? (planes[1].bytesPerPixel ?? 1) : 1,
        sentAtUs: DateTime.now().microsecondsSinceEpoch,
      ),
    );
    return true;
  }

  /// JPEG of the most recently processed camera frame, upright. Encoded in
  /// the worker; the camera stream is never stopped.
  Future<Uint8List?> requestSnapshot({int jpegQuality = 80}) async {
    final port = _workerPort;
    if (port == null || !isReady) return null;
    final id = _nextId++;
    final completer = Completer<Object>();
    _pending[id] = completer;
    port.send(SnapshotMsg(id: id, jpegQuality: jpegQuality));
    final result = await completer.future.timeout(
      const Duration(seconds: 5),
      onTimeout: () {
        _pending.remove(id);
        throw TimeoutException('Snapshot timed out');
      },
    );
    final snapshot = result as SnapshotResult;
    if (snapshot.error != null) {
      debugPrint('⚠️ snapshot failed: ${snapshot.error}');
      return null;
    }
    return snapshot.jpeg;
  }

  /// Manual mode (report screen): run the model on a still image.
  /// Returns `{'label': String, 'detections': List<Map>, 'maxScore': double}`.
  Future<Map<String, dynamic>> predictImage(String imagePath) async {
    await initialize();
    final port = _workerPort;
    if (port == null || !isReady) return _emptyResult;
    final id = _nextId++;
    final completer = Completer<Object>();
    _pending[id] = completer;
    port.send(PredictFileMsg(id: id, path: imagePath));
    try {
      final result = await completer.future.timeout(
        const Duration(seconds: 30),
        onTimeout: () {
          _pending.remove(id);
          throw TimeoutException('Image prediction timed out');
        },
      );
      final detection = DetectionResult._(result as ResultMsg, _labels);
      if (detection.error != null) {
        debugPrint('❌ predictImage: ${detection.error}');
        return _emptyResult;
      }
      final maps = detection.toDetectionMaps();
      String bestLabel = 'Clear Road';
      double best = 0.0;
      for (final m in maps) {
        final conf = m['conf'] as double;
        if (conf > best) {
          best = conf;
          bestLabel = m['label'] as String;
        }
      }
      return <String, dynamic>{
        'label': bestLabel,
        'detections': maps,
        'maxScore': best,
      };
    } catch (e) {
      debugPrint('❌ predictImage failed: $e');
      return _emptyResult;
    }
  }

  static Map<String, dynamic> get _emptyResult => <String, dynamic>{
    'label': 'Clear Road',
    'detections': const <Map<String, dynamic>>[],
    'maxScore': 0.0,
  };

  // ===========================================================================
  // Diagnostics
  // ===========================================================================

  void _addEvent(String event) {
    const maxEvents = 5;
    final next = <String>[..._diagnosticEvents.value, event];
    if (next.length > maxEvents) {
      next.removeRange(0, next.length - maxEvents);
    }
    _diagnosticEvents.value = List<String>.unmodifiable(next);
  }

  static String _short(String text) {
    final single = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    return single.length <= 96 ? single : '${single.substring(0, 93)}…';
  }
}

/// One processed frame, as seen from the main isolate.
class DetectionResult {
  DetectionResult._(this._msg, this._labels)
      : receivedAtUs = DateTime.now().microsecondsSinceEpoch;

  final ResultMsg _msg;
  final List<String> _labels;
  final int receivedAtUs;

  int get id => _msg.id;
  String? get error => _msg.error;
  double get maxScore => _msg.maxScore;
  int get count => _msg.count;
  String get backend => _msg.backend;

  int get preprocessUs => _msg.tPreUs;
  int get setInputUs => _msg.tSetUs;
  int get invokeUs => _msg.tInvUs;
  int get postprocessUs => _msg.tPostUs;
  int get totalUs => _msg.tTotalUs;

  /// Camera callback → result delivered, including isolate hops.
  int get roundTripUs =>
      _msg.sentAtUs == 0 ? totalUs : receivedAtUs - _msg.sentAtUs;

  /// Letterbox geometry needed to draw boxes on the preview.
  LetterboxGeometry get letterbox => LetterboxGeometry(
    padXNorm: _msg.padXNorm,
    padYNorm: _msg.padYNorm,
    contentWNorm: _msg.contentWNorm,
    contentHNorm: _msg.contentHNorm,
    contentAspect: _msg.contentAspect,
  );

  /// Legacy map shape used by the painter and the report screen:
  /// `{x1, y1, x2, y2, conf, label}` with 0–1 coordinates in the letterboxed
  /// model input space.
  List<Map<String, dynamic>> toDetectionMaps() {
    final boxes = _msg.boxes;
    final n = boxes.length ~/ 6;
    if (n == 0) return const <Map<String, dynamic>>[];
    final result = <Map<String, dynamic>>[];
    for (int i = 0; i < n; i++) {
      final base = i * 6;
      final classId = boxes[base + 5].round();
      result.add(<String, dynamic>{
        'x1': boxes[base].toDouble(),
        'y1': boxes[base + 1].toDouble(),
        'x2': boxes[base + 2].toDouble(),
        'y2': boxes[base + 3].toDouble(),
        'conf': boxes[base + 4].toDouble(),
        'label': classId >= 0 && classId < _labels.length
            ? _labels[classId]
            : 'Class $classId',
      });
    }
    return result;
  }
}

/// Where the camera content sits inside the square model input, normalised.
class LetterboxGeometry {
  const LetterboxGeometry({
    required this.padXNorm,
    required this.padYNorm,
    required this.contentWNorm,
    required this.contentHNorm,
    required this.contentAspect,
  });

  final double padXNorm;
  final double padYNorm;
  final double contentWNorm;
  final double contentHNorm;

  /// Width / height of the upright camera frame.
  final double contentAspect;

  @override
  bool operator ==(Object other) =>
      other is LetterboxGeometry &&
      other.padXNorm == padXNorm &&
      other.padYNorm == padYNorm &&
      other.contentWNorm == contentWNorm &&
      other.contentHNorm == contentHNorm &&
      other.contentAspect == contentAspect;

  @override
  int get hashCode =>
      Object.hash(padXNorm, padYNorm, contentWNorm, contentHNorm, contentAspect);
}
