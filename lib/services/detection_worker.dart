/// Background detection worker.
///
/// Everything that costs time per camera frame lives here, inside its own
/// isolate: backend selection, YUV→RGB letterboxing, `invoke()`, output
/// decoding, and the JPEG encode for pothole reports. The UI isolate only
/// forwards camera planes and receives a tiny detection list, so the preview
/// never stutters no matter how slow the model is.
///
/// Design rules:
///  * The worker OWNS the [Interpreter] and any delegate. They are created and
///    invoked on this isolate only. (The earlier isolate attempt, commit
///    9d83b08, also created the interpreter in-isolate but invoked it with
///    `interpreter.run([Float32List], out)`, which makes tflite_flutter resize
///    the input tensor to `[1, N]` and fail with the bare
///    `Bad state: failed precondition`. We always write the input through the
///    tensor's byte view instead, never through `run()`.)
///  * No Flutter imports: `rootBundle` is unavailable here, so the model bytes
///    arrive from the main isolate and the model is opened with
///    [Interpreter.fromBuffer].
///  * Hot-path messages are plain typed data — no `Map<String, dynamic>`.
library;

import 'dart:ffi' show StructPointer; // `.ref` on the XNNPACK options pointer
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:tflite_flutter/tflite_flutter.dart';

import 'frame_sampler.dart';

export 'frame_sampler.dart' show FrameFormat;

// TfLiteGpuInferenceUsage / TfLiteGpuInferencePriority (TFLite C API values).
const int _kGpuUsageFastSingleAnswer = 0;
const int _kGpuPriorityAuto = 0;
const int _kGpuPriorityMinLatency = 2;

// =============================================================================
// Messages: main → worker
// =============================================================================

class WorkerInit {
  const WorkerInit({
    required this.mainPort,
    required this.modelBytes,
    required this.labels,
    required this.confThreshold,
    required this.iouThreshold,
    required this.preferGpu,
    required this.allowNnapi,
    required this.cpuThreads,
    required this.gpuMaxPartitions,
    required this.rotationDegrees,
    this.allowCpuFp16 = true,
  });

  final SendPort mainPort;
  final TransferableTypedData modelBytes;
  final List<String> labels;
  final double confThreshold;
  final double iouThreshold;
  final bool preferGpu;
  final bool allowNnapi;
  final int cpuThreads;
  final int gpuMaxPartitions;

  /// Clockwise rotation that turns a raw camera frame upright (0/90/180/270).
  final int rotationDegrees;

  /// On the CPU path, let XNNPACK run FP32 operators in FP16 arithmetic
  /// (ARMv8.2+). Same trade as the GPU path; ignored by CPUs without FP16.
  final bool allowCpuFp16;
}

class FrameMsg {
  const FrameMsg({
    required this.id,
    required this.width,
    required this.height,
    required this.format,
    required this.plane0,
    required this.rowStride0,
    required this.sentAtUs,
    this.plane1,
    this.plane2,
    this.rowStride1 = 0,
    this.pixelStride1 = 1,
  });

  final int id;
  final int width;
  final int height;
  final int format;
  final Uint8List plane0;
  final Uint8List? plane1;
  final Uint8List? plane2;

  /// Bytes per row of [plane0] (Y plane, BGRA row, or RGB row).
  final int rowStride0;

  /// Bytes per row / bytes per pixel of the chroma planes (YUV only).
  final int rowStride1;
  final int pixelStride1;
  final int sentAtUs;
}

class SnapshotMsg {
  const SnapshotMsg({required this.id, this.jpegQuality = 80});
  final int id;
  final int jpegQuality;
}

class PredictFileMsg {
  const PredictFileMsg({required this.id, required this.path});
  final int id;
  final String path;
}

class SetRotationMsg {
  const SetRotationMsg(this.degrees);
  final int degrees;
}

class CloseMsg {
  const CloseMsg();
}

// =============================================================================
// Messages: worker → main
// =============================================================================

class WorkerReady {
  const WorkerReady({
    required this.port,
    required this.backend,
    required this.inputWidth,
    required this.inputHeight,
    required this.channelsFirst,
    required this.inputType,
    required this.outputShape,
    required this.outputLayout,
    required this.warmupMs,
  });

  final SendPort port;
  final String backend;
  final int inputWidth;
  final int inputHeight;
  final bool channelsFirst;
  final String inputType;
  final List<int> outputShape;
  final String outputLayout;
  final int warmupMs;
}

class WorkerFatal {
  const WorkerFatal(this.message);
  final String message;
}

class WorkerEvent {
  const WorkerEvent(this.message, {this.isError = false});
  final String message;
  final bool isError;
}

class ResultMsg {
  const ResultMsg({
    required this.id,
    required this.boxes,
    required this.maxScore,
    required this.tPreUs,
    required this.tSetUs,
    required this.tInvUs,
    required this.tPostUs,
    required this.sentAtUs,
    required this.padXNorm,
    required this.padYNorm,
    required this.contentWNorm,
    required this.contentHNorm,
    required this.contentAspect,
    required this.backend,
    this.error,
  });

  final int id;

  /// Flat `[x1, y1, x2, y2, conf, classId] * n`, normalised 0–1 in the
  /// letterboxed model input space.
  final Float32List boxes;
  final double maxScore;
  final int tPreUs;
  final int tSetUs;
  final int tInvUs;
  final int tPostUs;
  final int sentAtUs;

  /// Letterbox geometry (normalised to the model input) so the UI can map
  /// boxes back onto the camera preview.
  final double padXNorm;
  final double padYNorm;
  final double contentWNorm;
  final double contentHNorm;

  /// Width / height of the upright camera frame.
  final double contentAspect;
  final String backend;
  final String? error;

  int get tTotalUs => tPreUs + tSetUs + tInvUs + tPostUs;
  int get count => boxes.length ~/ 6;
}

class SnapshotResult {
  const SnapshotResult({
    required this.id,
    this.jpeg,
    this.width = 0,
    this.height = 0,
    this.error,
  });

  final int id;
  final Uint8List? jpeg;
  final int width;
  final int height;
  final String? error;
}

// =============================================================================
// Isolate entry point
// =============================================================================

Future<void> detectionWorkerMain(WorkerInit init) async {
  final receivePort = ReceivePort();
  final worker = _Worker(init);

  try {
    await worker.start(receivePort.sendPort);
  } catch (e, stack) {
    init.mainPort.send(WorkerFatal('$e\n$stack'));
    worker.close();
    receivePort.close();
    return;
  }

  await for (final Object? message in receivePort) {
    if (message is FrameMsg) {
      init.mainPort.send(worker.processFrame(message, keepAsLast: true));
    } else if (message is SnapshotMsg) {
      init.mainPort.send(worker.snapshot(message));
    } else if (message is PredictFileMsg) {
      init.mainPort.send(worker.predictFile(message));
    } else if (message is SetRotationMsg) {
      worker.setRotation(message.degrees);
    } else if (message is CloseMsg) {
      break;
    }
  }

  worker.close();
  receivePort.close();
}

enum _OutputLayout {
  /// `[1, max_det, 6]` — Ultralytics end-to-end export (top-k already applied).
  endToEnd,

  /// `[1, anchors, 4 + nc]` — one-to-one head with the top-k tail stripped
  /// (xyxy pixels + class scores). GPU-friendly; needs only a score filter.
  rowsRaw,

  /// `[1, 4 + nc, anchors]` — legacy raw head (cx, cy, w, h + scores) + NMS.
  colsRaw,
}

class _Worker {
  _Worker(this._init)
      : _rotation = _normalizeRotation(_init.rotationDegrees);

  static int _normalizeRotation(int deg) {
    final n = ((deg % 360) + 360) % 360;
    return (n == 90 || n == 180 || n == 270) ? n : 0;
  }

  final WorkerInit _init;
  SendPort get _main => _init.mainPort;

  late final Uint8List _modelBytes;
  late final List<String> _labels;

  Interpreter? _interpreter;
  GpuDelegateV2? _gpuDelegate;
  XNNPackDelegate? _xnnDelegate;
  String _backend = 'unknown';
  String? _lastFailure;

  // --- model metadata ---
  int _inputW = 0;
  int _inputH = 0;
  bool _channelsFirst = false;
  TensorType _inputType = TensorType.float32;
  double _inputScale = 1.0;
  int _inputZeroPoint = 0;
  List<int> _outputShape = const <int>[];
  TensorType _outputType = TensorType.float32;
  double _outputScale = 1.0;
  int _outputZeroPoint = 0;
  _OutputLayout _layout = _OutputLayout.endToEnd;

  // --- reusable buffers ---
  /// Letterbox + rotation + colour conversion into the model input buffer
  /// (pure Dart, unit-tested in test/frame_sampler_test.dart).
  FrameSampler? _sampler;
  late Uint8List _inBytes;
  late Float32List _outF;

  int _rotation;

  final Stopwatch _sw = Stopwatch();
  FrameMsg? _lastFrame;

  // ===========================================================================
  // Startup
  // ===========================================================================

  Future<void> start(SendPort selfPort) async {
    _modelBytes = _init.modelBytes.materialize().asUint8List();
    _labels = List<String>.unmodifiable(_init.labels);
    if (_labels.isEmpty) {
      throw StateError('classes.txt is empty; YOLO labels are required.');
    }

    final warmup = Stopwatch()..start();
    await _selectBackend();
    final interpreter = _interpreter;
    if (interpreter == null) {
      throw StateError(
        'No backend could run the model. ${_lastFailure ?? ''}'.trim(),
      );
    }
    _readModelMetadata(interpreter);
    warmup.stop();

    _main.send(
      WorkerReady(
        port: selfPort,
        backend: _backend,
        inputWidth: _inputW,
        inputHeight: _inputH,
        channelsFirst: _channelsFirst,
        inputType: _inputType.toString(),
        outputShape: List<int>.from(_outputShape),
        outputLayout: _layout.name,
        warmupMs: warmup.elapsedMilliseconds,
      ),
    );
  }

  void _event(String message, {bool isError = false}) {
    _main.send(WorkerEvent(message, isError: isError));
  }

  /// GPU (if allowed) → NNAPI (opt-in) → CPU/XNNPACK. Each candidate must
  /// survive a real `invoke()` before it is accepted: some drivers accept the
  /// graph at creation and only reject it on the first run.
  Future<void> _selectBackend() async {
    if (_init.preferGpu) {
      if (_tryGpu()) {
        // Dart isolates are not pinned to one OS thread. The OpenGL GPU
        // backend refuses to invoke on a thread other than the one it was
        // prepared on; OpenCL only warns. Yield so the isolate can migrate,
        // then invoke again — if that fails here it would fail in the field.
        await Future<void>.delayed(const Duration(milliseconds: 300));
        try {
          _verifyInvoke(_interpreter!);
          _event('AI | GPU ready');
          return;
        } catch (e) {
          _recordFailure('GPU (thread affinity)', e);
          _closeInterpreter();
        }
      }
    }
    if (_init.allowNnapi && Platform.isAndroid) {
      if (_tryNnapi()) {
        _event('AI | NNAPI ready');
        return;
      }
    }
    if (_tryCpu()) {
      _event('AI | CPU/XNNPACK ready ($_backend)');
    }
  }

  bool _tryGpu() {
    Interpreter? interpreter;
    GpuDelegateV2? delegate;
    try {
      _event('AI | Testing GPU delegate…');
      final gpuOptions = GpuDelegateOptionsV2(
        isPrecisionLossAllowed: true, // fp16 internally: big speed win
        inferencePreference: _kGpuUsageFastSingleAnswer,
        inferencePriority1: _kGpuPriorityMinLatency,
        inferencePriority2: _kGpuPriorityAuto,
        inferencePriority3: _kGpuPriorityAuto,
        maxDelegatePartitions: _init.gpuMaxPartitions,
      );
      try {
        delegate = GpuDelegateV2(options: gpuOptions);
      } finally {
        gpuOptions.delete();
      }
      final options = InterpreterOptions()..addDelegate(delegate);
      final Interpreter created;
      try {
        created = Interpreter.fromBuffer(_modelBytes, options: options);
      } catch (_) {
        options.delete();
        rethrow;
      }
      options.delete();
      interpreter = created;
      // Two warm-ups: the first compiles kernels (can take seconds), the
      // second proves steady-state invoke works.
      _verifyInvoke(created);
      _verifyInvoke(created);
      _interpreter = created;
      _gpuDelegate = delegate;
      _backend = 'GPU';
      return true;
    } catch (e) {
      interpreter?.close();
      delegate?.delete();
      _recordFailure('GPU', e);
      return false;
    }
  }

  bool _tryNnapi() {
    Interpreter? interpreter;
    try {
      _event('AI | Testing NNAPI delegate…');
      final options = InterpreterOptions()..useNnApiForAndroid = true;
      final Interpreter created;
      try {
        created = Interpreter.fromBuffer(_modelBytes, options: options);
      } catch (_) {
        options.delete();
        rethrow;
      }
      options.delete();
      interpreter = created;
      _verifyInvoke(created);
      _interpreter = created;
      _backend = 'NNAPI';
      return true;
    } catch (e) {
      interpreter?.close();
      _recordFailure('NNAPI', e);
      return false;
    }
  }

  /// CPU path. XNNPACK is the fast CPU engine. The bundled LiteRT library
  /// normally applies it by default for float models, but we add it
  /// explicitly so the thread count and flags are certain, and so FP32
  /// operators can run in FP16 arithmetic (ARMv8.2+): roughly 1.3–1.8×
  /// faster for conv nets with negligible accuracy loss — the same trade the
  /// GPU path makes. Order: XNNPACK+FP16 → XNNPACK → plain interpreter.
  bool _tryCpu() {
    final threads = _init.cpuThreads < 1 ? 1 : _init.cpuThreads;
    if (_init.allowCpuFp16 && _tryXnnpack(threads, forceFp16: true)) {
      return true;
    }
    if (_tryXnnpack(threads, forceFp16: false)) return true;
    return _tryPlainCpu(threads);
  }

  // TfLiteXNNPackDelegateOptions.flags (C API, stable values).
  static const int _kXnnFlagQs8 = 1;
  static const int _kXnnFlagQu8 = 2;
  static const int _kXnnFlagForceFp16 = 4;

  bool _tryXnnpack(int threads, {required bool forceFp16}) {
    final label = forceFp16 ? 'CPU/XNNPACK-fp16' : 'CPU/XNNPACK';
    Interpreter? interpreter;
    XNNPackDelegate? delegate;
    try {
      _event('AI | Testing $label ($threads threads)…');
      final xnnOptions = XNNPackDelegateOptions(numThreads: threads);
      final XNNPackDelegate xnn;
      try {
        // Keep quantised-op support (the library default) and optionally
        // force FP16 for FP32 operators.
        xnnOptions.base.ref.flags = _kXnnFlagQs8 |
            _kXnnFlagQu8 |
            (forceFp16 ? _kXnnFlagForceFp16 : 0);
        xnn = XNNPackDelegate(options: xnnOptions);
      } catch (_) {
        xnnOptions.delete();
        rethrow;
      }
      xnnOptions.delete();
      delegate = xnn;

      final options = InterpreterOptions()
        ..threads = threads
        ..addDelegate(xnn);
      final Interpreter created;
      try {
        created = Interpreter.fromBuffer(_modelBytes, options: options);
      } catch (_) {
        options.delete();
        rethrow;
      }
      options.delete();
      interpreter = created;
      // Two warm-ups: the first packs weights (FP16 conversion happens here).
      _verifyInvoke(created);
      _verifyInvoke(created);
      _interpreter = created;
      _xnnDelegate = xnn;
      _backend = '$label ($threads thr)';
      return true;
    } catch (e) {
      interpreter?.close();
      delegate?.delete();
      _recordFailure(label, e);
      return false;
    }
  }

  bool _tryPlainCpu(int threads) {
    Interpreter? interpreter;
    try {
      _event('AI | Testing CPU ($threads threads)…');
      final options = InterpreterOptions()..threads = threads;
      final Interpreter created;
      try {
        created = Interpreter.fromBuffer(_modelBytes, options: options);
      } catch (_) {
        options.delete();
        rethrow;
      }
      options.delete();
      interpreter = created;
      _verifyInvoke(created);
      _interpreter = created;
      _backend = 'CPU ($threads thr)';
      return true;
    } catch (e) {
      interpreter?.close();
      _recordFailure('CPU', e);
      return false;
    }
  }

  /// Zero input of the tensor's real byte length, then invoke. Zero bytes are
  /// valid for every supported dtype; this only tests backend compatibility.
  static void _verifyInvoke(Interpreter interpreter) {
    final input = interpreter.getInputTensor(0);
    input.setTo(Uint8List(input.numBytes()));
    interpreter.invoke();
  }

  void _recordFailure(String backend, Object error) {
    _lastFailure = '$backend warm-up failed: $error';
    _event('AI | $backend rejected graph | ${_shortError(error)}');
  }

  static String _shortError(Object error) {
    final single = error.toString().replaceAll(RegExp(r'\s+'), ' ').trim();
    return single.length <= 96 ? single : '${single.substring(0, 93)}…';
  }

  void _closeInterpreter() {
    _interpreter?.close();
    _gpuDelegate?.delete();
    _xnnDelegate?.delete();
    _interpreter = null;
    _gpuDelegate = null;
    _xnnDelegate = null;
    _backend = 'unknown';
  }

  void _readModelMetadata(Interpreter interpreter) {
    final inputTensor = interpreter.getInputTensor(0);
    final inputShape = inputTensor.shape;
    final isNhwc = inputShape.length == 4 && inputShape[3] == 3;
    final isNchw = inputShape.length == 4 && inputShape[1] == 3;
    if (inputShape.length != 4 || inputShape[0] != 1 || !(isNhwc || isNchw)) {
      throw StateError(
        'Unsupported model input shape $inputShape. '
        'Expected [1,H,W,3] or [1,3,H,W].',
      );
    }
    _channelsFirst = isNchw;
    _inputH = isNchw ? inputShape[2] : inputShape[1];
    _inputW = isNchw ? inputShape[3] : inputShape[2];
    _inputType = inputTensor.type;
    _inputScale = inputTensor.params.scale;
    _inputZeroPoint = inputTensor.params.zeroPoint;

    final SamplerInputType samplerType;
    switch (_inputType) {
      case TensorType.float32:
        samplerType = SamplerInputType.float32;
      case TensorType.uint8:
        samplerType = SamplerInputType.uint8;
      case TensorType.int8:
        samplerType = SamplerInputType.int8;
      default:
        throw StateError(
          'Unsupported model input type $_inputType. '
          'Expected float32, uint8 or int8.',
        );
    }
    final sampler = FrameSampler(
      inputWidth: _inputW,
      inputHeight: _inputH,
      channelsFirst: _channelsFirst,
      inputType: samplerType,
      inputScale: _inputScale,
      inputZeroPoint: _inputZeroPoint,
    );
    _sampler = sampler;
    _inBytes = sampler.inputBytes;
    if (inputTensor.numBytes() != _inBytes.length) {
      throw StateError(
        'Input tensor is ${inputTensor.numBytes()} bytes but the frame '
        'buffer is ${_inBytes.length} bytes ($inputShape, $_inputType).',
      );
    }

    final outputTensor = interpreter.getOutputTensor(0);
    _outputShape = List<int>.from(outputTensor.shape);
    _outputType = outputTensor.type;
    _outputScale = outputTensor.params.scale;
    _outputZeroPoint = outputTensor.params.zeroPoint;
    if (_outputType != TensorType.float32 &&
        _outputType != TensorType.int8 &&
        _outputType != TensorType.uint8) {
      throw StateError('Unsupported model output type $_outputType.');
    }

    final os = _outputShape;
    final nc = _labels.length;
    if (os.length != 3 || os[0] != 1) {
      throw StateError('Unknown YOLO output shape $os.');
    }
    if (os[2] == 6 && !(nc == 2 && os[1] > 1000)) {
      _layout = _OutputLayout.endToEnd;
    } else if (os[2] == 4 + nc) {
      _layout = _OutputLayout.rowsRaw;
    } else if (os[1] == 4 + nc) {
      _layout = _OutputLayout.colsRaw;
    } else {
      throw StateError(
        'YOLO output $os does not match $nc label(s) in classes.txt. '
        'Expected [1,N,6], [1,N,${4 + nc}] or [1,${4 + nc},N].',
      );
    }
    _outF = Float32List(os[1] * os[2]);

    _event(
      'AI | Model ${_inputW}x$_inputH ${_channelsFirst ? 'NCHW' : 'NHWC'} '
      '${_inputType.name} → $os ${_layout.name}',
    );
  }

  void setRotation(int degrees) {
    _rotation = _normalizeRotation(degrees);
  }

  void close() {
    _closeInterpreter();
    _lastFrame = null;
  }

  // ===========================================================================
  // Per-frame pipeline
  // ===========================================================================

  ResultMsg processFrame(FrameMsg frame, {required bool keepAsLast}) {
    final interpreter = _interpreter;
    final sampler = _sampler;
    if (interpreter == null || sampler == null) {
      return _errorResult(frame, 'Interpreter is not initialised');
    }
    String stage = 'letterbox + colour conversion';
    try {
      _sw
        ..reset()
        ..start();
      sampler.fill(
        width: frame.width,
        height: frame.height,
        format: frame.format,
        plane0: frame.plane0,
        plane1: frame.plane1,
        plane2: frame.plane2,
        rowStride0: frame.rowStride0,
        rowStride1: frame.rowStride1,
        pixelStride1: frame.pixelStride1,
        rotation: _rotation,
      );
      final tPre = _sw.elapsedMicroseconds;

      stage = 'copy input to tensor';
      _setInput();
      final tSet = _sw.elapsedMicroseconds - tPre;

      stage = 'invoke';
      _invokeWithFallback();
      final tInv = _sw.elapsedMicroseconds - tPre - tSet;

      stage = 'read + decode output';
      _readOutput();
      double maxScore = 0.0;
      final boxes = _decodeBoxes((score) {
        if (score > maxScore) maxScore = score;
      });
      final tPost = _sw.elapsedMicroseconds - tPre - tSet - tInv;

      if (keepAsLast) _lastFrame = frame;

      return ResultMsg(
        id: frame.id,
        boxes: boxes,
        maxScore: maxScore,
        tPreUs: tPre,
        tSetUs: tSet,
        tInvUs: tInv,
        tPostUs: tPost,
        sentAtUs: frame.sentAtUs,
        padXNorm: sampler.padXNorm,
        padYNorm: sampler.padYNorm,
        contentWNorm: sampler.contentWNorm,
        contentHNorm: sampler.contentHNorm,
        contentAspect: sampler.contentAspect,
        backend: _backend,
      );
    } catch (e) {
      return _errorResult(frame, '$stage: $e');
    }
  }

  ResultMsg _errorResult(FrameMsg frame, String error) {
    final s = _sampler;
    return ResultMsg(
      id: frame.id,
      boxes: Float32List(0),
      maxScore: 0.0,
      tPreUs: 0,
      tSetUs: 0,
      tInvUs: 0,
      tPostUs: 0,
      sentAtUs: frame.sentAtUs,
      padXNorm: s?.padXNorm ?? 0,
      padYNorm: s?.padYNorm ?? 0,
      contentWNorm: s?.contentWNorm ?? 1,
      contentHNorm: s?.contentHNorm ?? 1,
      contentAspect: s?.contentAspect ?? 1,
      backend: _backend,
      error: 'backend=$_backend | $error',
    );
  }

  void _setInput() {
    // One `setRange` straight into tensor memory. (`setTo` would malloc and
    // copy twice per frame.)
    _interpreter!.getInputTensor(0).data = _inBytes;
  }

  void _invokeWithFallback() {
    try {
      _interpreter!.invoke();
    } catch (e) {
      final accelerated = _backend == 'GPU' || _backend == 'NNAPI';
      if (!accelerated) rethrow;
      _event(
        'AI | $_backend invoke failed (${_shortError(e)}) → CPU/XNNPACK',
        isError: true,
      );
      _closeInterpreter();
      if (!_tryCpu()) {
        throw StateError('CPU fallback failed: ${_lastFailure ?? e}');
      }
      _setInput();
      _interpreter!.invoke();
    }
  }

  void _readOutput() {
    final tensor = _interpreter!.getOutputTensor(0);
    final Uint8List raw = tensor.data;
    final count = _outF.length;
    switch (_outputType) {
      case TensorType.float32:
        final view = raw.buffer.asFloat32List(raw.offsetInBytes, count);
        _outF.setAll(0, view);
      case TensorType.int8:
        final view = raw.buffer.asInt8List(raw.offsetInBytes, count);
        final scale = _outputScale == 0 ? 1.0 : _outputScale;
        for (int i = 0; i < count; i++) {
          _outF[i] = (view[i] - _outputZeroPoint) * scale;
        }
      case TensorType.uint8:
        final scale = _outputScale == 0 ? 1.0 : _outputScale;
        for (int i = 0; i < count; i++) {
          _outF[i] = (raw[i] - _outputZeroPoint) * scale;
        }
      default:
        throw StateError('Unsupported output type $_outputType');
    }
  }

  // ---------------------------------------------------------------------------
  // Output decoding → flat [x1, y1, x2, y2, conf, cls] normalised 0–1.
  // ---------------------------------------------------------------------------

  Float32List _decodeBoxes(void Function(double score) onScore) {
    final out = _outF;
    final nc = _labels.length;
    final thr = _init.confThreshold;
    final w = _inputW.toDouble();
    final h = _inputH.toDouble();
    final cand = <double>[];

    switch (_layout) {
      case _OutputLayout.endToEnd:
        final n = _outputShape[1];
        for (int i = 0; i < n; i++) {
          final base = i * 6;
          final conf = out[base + 4];
          onScore(conf); // true max, even below threshold (diagnostics)
          if (conf < thr) continue;
          _pushXyxy(cand, out[base], out[base + 1], out[base + 2],
              out[base + 3], conf, out[base + 5], w, h);
        }
      case _OutputLayout.rowsRaw:
        final n = _outputShape[1];
        final stride = _outputShape[2];
        for (int i = 0; i < n; i++) {
          final base = i * stride;
          double best = 0.0;
          int bestCls = 0;
          for (int c = 0; c < nc; c++) {
            final s = out[base + 4 + c];
            if (s > best) {
              best = s;
              bestCls = c;
            }
          }
          onScore(best);
          if (best < thr) continue;
          _pushXyxy(cand, out[base], out[base + 1], out[base + 2],
              out[base + 3], best, bestCls.toDouble(), w, h);
        }
      case _OutputLayout.colsRaw:
        final n = _outputShape[2];
        for (int a = 0; a < n; a++) {
          double best = 0.0;
          int bestCls = 0;
          for (int c = 0; c < nc; c++) {
            final s = out[(4 + c) * n + a];
            if (s > best) {
              best = s;
              bestCls = c;
            }
          }
          onScore(best);
          if (best < thr) continue;
          final cx = out[a];
          final cy = out[n + a];
          final bw = out[2 * n + a];
          final bh = out[3 * n + a];
          _pushXyxy(cand, cx - bw / 2, cy - bh / 2, cx + bw / 2, cy + bh / 2,
              best, bestCls.toDouble(), w, h);
        }
    }

    if (_layout != _OutputLayout.endToEnd && cand.length > 6) {
      return Float32List.fromList(_nms(cand, _init.iouThreshold));
    }
    return Float32List.fromList(cand);
  }

  /// Some exports emit pixel coordinates, others normalised ones. Anything
  /// above 2 cannot be normalised, so it is divided by the model input size
  /// (the old code hard-coded 640 here, which breaks any other input size).
  static void _pushXyxy(
    List<double> cand,
    double x1,
    double y1,
    double x2,
    double y2,
    double conf,
    double cls,
    double w,
    double h,
  ) {
    final pixels =
        x1.abs() > 2 || y1.abs() > 2 || x2.abs() > 2 || y2.abs() > 2;
    final sx = pixels ? 1.0 / w : 1.0;
    final sy = pixels ? 1.0 / h : 1.0;
    cand
      ..add((x1 * sx).clamp(0.0, 1.0))
      ..add((y1 * sy).clamp(0.0, 1.0))
      ..add((x2 * sx).clamp(0.0, 1.0))
      ..add((y2 * sy).clamp(0.0, 1.0))
      ..add(conf)
      ..add(cls);
  }

  static List<double> _nms(List<double> flat, double iouThreshold) {
    final n = flat.length ~/ 6;
    final order = List<int>.generate(n, (i) => i)
      ..sort((a, b) => flat[b * 6 + 4].compareTo(flat[a * 6 + 4]));
    final kept = <int>[];
    for (final i in order) {
      bool suppressed = false;
      for (final k in kept) {
        if (_iou(flat, i, k) > iouThreshold) {
          suppressed = true;
          break;
        }
      }
      if (!suppressed) kept.add(i);
      if (kept.length >= 50) break;
    }
    final result = <double>[];
    for (final i in kept) {
      result.addAll(flat.getRange(i * 6, i * 6 + 6));
    }
    return result;
  }

  static double _iou(List<double> f, int i, int j) {
    final a = i * 6, b = j * 6;
    final x1 = math.max(f[a], f[b]);
    final y1 = math.max(f[a + 1], f[b + 1]);
    final x2 = math.min(f[a + 2], f[b + 2]);
    final y2 = math.min(f[a + 3], f[b + 3]);
    final iw = math.max(0.0, x2 - x1);
    final ih = math.max(0.0, y2 - y1);
    final inter = iw * ih;
    final areaA = (f[a + 2] - f[a]) * (f[a + 3] - f[a + 1]);
    final areaB = (f[b + 2] - f[b]) * (f[b + 3] - f[b + 1]);
    final union = areaA + areaB - inter;
    return union <= 0 ? 0.0 : inter / union;
  }

  // ===========================================================================
  // Report photo: JPEG of the last processed camera frame
  // ===========================================================================

  SnapshotResult snapshot(SnapshotMsg msg) {
    final frame = _lastFrame;
    if (frame == null) {
      return SnapshotResult(id: msg.id, error: 'No camera frame yet');
    }
    try {
      final rgb = _frameToRgb(frame);
      var image = img.Image.fromBytes(
        width: frame.width,
        height: frame.height,
        bytes: rgb.buffer,
        numChannels: 3,
      );
      if (_rotation != 0) {
        image = img.copyRotate(image, angle: _rotation);
      }
      final jpeg = img.encodeJpg(image, quality: msg.jpegQuality);
      return SnapshotResult(
        id: msg.id,
        jpeg: jpeg,
        width: image.width,
        height: image.height,
      );
    } catch (e) {
      return SnapshotResult(id: msg.id, error: 'snapshot: $e');
    }
  }

  static Uint8List _frameToRgb(FrameMsg f) {
    final w = f.width, h = f.height;
    final rgb = Uint8List(w * h * 3);
    final p0 = f.plane0;
    int o = 0;
    switch (f.format) {
      case FrameFormat.yuv420:
        final p1 = f.plane1!, p2 = f.plane2!;
        final yStride = f.rowStride0, uvStride = f.rowStride1;
        final uvPix = f.pixelStride1;
        for (int y = 0; y < h; y++) {
          final yRow = y * yStride;
          final uvRow = (y >> 1) * uvStride;
          for (int x = 0; x < w; x++) {
            final yp = p0[yRow + x];
            final uvIdx = uvRow + (x >> 1) * uvPix;
            final u = p1[uvIdx] - 128;
            final v = p2[uvIdx] - 128;
            int r = yp + ((v * 1436) >> 10);
            int g = yp - ((u * 352) >> 10) - ((v * 731) >> 10);
            int b = yp + ((u * 1814) >> 10);
            rgb[o++] = r < 0 ? 0 : (r > 255 ? 255 : r);
            rgb[o++] = g < 0 ? 0 : (g > 255 ? 255 : g);
            rgb[o++] = b < 0 ? 0 : (b > 255 ? 255 : b);
          }
        }
      case FrameFormat.bgra8888:
        for (int y = 0; y < h; y++) {
          int s = y * f.rowStride0;
          for (int x = 0; x < w; x++, s += 4) {
            rgb[o++] = p0[s + 2];
            rgb[o++] = p0[s + 1];
            rgb[o++] = p0[s];
          }
        }
      default:
        for (int y = 0; y < h; y++) {
          rgb.setRange(o, o + w * 3, p0, y * f.rowStride0);
          o += w * 3;
        }
    }
    return rgb;
  }

  // ===========================================================================
  // Manual mode: still image from disk
  // ===========================================================================

  ResultMsg predictFile(PredictFileMsg msg) {
    final placeholder = FrameMsg(
      id: msg.id,
      width: 1,
      height: 1,
      format: FrameFormat.rgb,
      plane0: Uint8List(3),
      rowStride0: 3,
      sentAtUs: 0,
    );
    if (_interpreter == null) {
      return _errorResult(placeholder, 'Interpreter is not initialised');
    }
    img.Image? decoded;
    try {
      decoded = img.decodeImage(File(msg.path).readAsBytesSync());
    } catch (e) {
      return _errorResult(placeholder, 'decode image: $e');
    }
    if (decoded == null) {
      return _errorResult(placeholder, 'Could not decode ${msg.path}');
    }

    // Linear downscale to the letterbox content size first, so the
    // nearest-neighbour sampler below is effectively an identity copy.
    final img.Image prepared;
    final Uint8List rgb;
    try {
      final scale =
          math.min(_inputW / decoded.width, _inputH / decoded.height);
      final targetW = math.max(1, (decoded.width * scale).round());
      final targetH = math.max(1, (decoded.height * scale).round());
      img.Image work = decoded;
      if (targetW != decoded.width || targetH != decoded.height) {
        work = img.copyResize(
          decoded,
          width: targetW,
          height: targetH,
          interpolation: img.Interpolation.linear,
        );
      }
      if (work.numChannels != 3 || work.format != img.Format.uint8) {
        work = work.convert(format: img.Format.uint8, numChannels: 3);
      }
      prepared = work;
      rgb = prepared.getBytes(order: img.ChannelOrder.rgb);
    } catch (e) {
      return _errorResult(placeholder, 'prepare image: $e');
    }
    final frame = FrameMsg(
      id: msg.id,
      width: prepared.width,
      height: prepared.height,
      format: FrameFormat.rgb,
      plane0: rgb,
      rowStride0: prepared.width * 3,
      sentAtUs: 0,
    );

    // Still images are already upright; do not apply the camera rotation.
    final savedRotation = _rotation;
    _rotation = 0;
    try {
      return processFrame(frame, keepAsLast: false);
    } finally {
      _rotation = savedRotation;
    }
  }
}
