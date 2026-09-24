import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart' show DeviceOrientation;
import 'package:geolocator/geolocator.dart';
import 'package:vibration/vibration.dart';

import '../services/api_service.dart';
import '../services/episode_log.dart';
import '../services/report_trigger_policy.dart';
import '../services/report_upload_queue.dart';
import '../services/tflite_service.dart';
import '../widgets/bounding_box_painter.dart';

/// Dashcam mode: continuous pothole detection while driving.
///
/// Hot path (per camera frame) does no work on the UI isolate except handing
/// the frame to [TFLiteService], which forwards it to the detection worker
/// isolate. Results come back through [TFLiteService.onResult].
///
/// Throughput rule: at most one frame is in the worker at a time. If frames
/// arrive while it is busy we keep only the newest and send it the moment a
/// result returns, so the processing rate always matches what the phone can
/// do — no fixed FPS throttle.
///
/// Reports never stop the stream: the worker JPEG-encodes the frame that
/// triggered the detection, GPS comes from a continuous stream, and the upload
/// is queued in [ReportUploadQueue].
class LiveCameraScreen extends StatefulWidget {
  const LiveCameraScreen({super.key});

  @override
  State<LiveCameraScreen> createState() => _LiveCameraScreenState();
}

class _LiveCameraScreenState extends State<LiveCameraScreen>
    with WidgetsBindingObserver {
  CameraController? _cameraController;
  final TFLiteService _ai = TFLiteService.instance;
  final ReportUploadQueue _uploads = ReportUploadQueue.instance;

  bool _isCameraInitialized = false;
  bool _isDetecting = false;

  // Only the painter and the HUD text listen to these; the rest of the tree
  // is never rebuilt per frame.
  final ValueNotifier<_Overlay> _overlay =
      ValueNotifier<_Overlay>(const _Overlay.empty());
  final ValueNotifier<String> _prediction =
      ValueNotifier<String>('Scanning road...');
  final ValueNotifier<String> _diagnostics =
      ValueNotifier<String>('AI: waiting for first frame…');

  // --- frame flow ---
  CameraImage? _pendingFrame;

  /// Ceiling on processed frames per second. Above ~15 FPS extra frames add
  /// nothing to detection (one frame per metre at 50 km/h, five confirming
  /// hits in 300 ms) but heat the phone, and a hot phone throttles. Frames
  /// arriving sooner than this interval are dropped.
  static const int maxProcessFps = 15;
  static const int _minDispatchIntervalUs = 1000000 ~/ maxProcessFps;
  int _lastDispatchUs = 0;

  final _FrameStats _stats = _FrameStats();
  int _lastDiagnosticLogTime = 0;
  int _lastFrameW = 0;
  int _lastFrameH = 0;
  TimingsCallback? _timingsCallback;

  // --- reporting ---
  /// Decides when an episode of detections becomes one report. Time-based
  /// and FPS-independent; gates and defaults live in
  /// `report_trigger_policy.dart`. Created lazily once the model input size
  /// is known, recreated on a model switch.
  ReportTriggerPolicy? _policy;
  final EpisodeLog _episodeLog = EpisodeLog.instance;

  /// Skip a new report within this distance of a recent one (same pothole
  /// on a return leg, or GPS drift while stopped in traffic).
  static const double _dedupeRadiusMeters = 20;
  static const int _maxRecentFixes = 200;

  /// Safety floor only. The episode model prevents duplicates; this catches
  /// an episode split by a long flicker at speed (> 400 ms at 70 km/h is
  /// more than the dedupe radius).
  static const int _minReportIntervalMs = 1000;

  /// At confirmation the pothole is still ~10–15 m ahead of the GPS antenna.
  static const double _lookAheadMeters = 12;

  int _lastReportUs = 0;
  final List<_GeoPoint> _recentReportFixes = <_GeoPoint>[];
  bool _snapshotInFlight = false;

  StreamSubscription<Position>? _gpsSub;
  Position? _latestFix;

  /// Heading (degrees) from the last fix taken while moving. Used to apply
  /// the look-ahead when the car is stopped, when GPS reports no heading.
  double? _lastMovingHeading;
  String? _gpsStatus;

  bool? _hasVibrator;
  VoidCallback? _outcomeListener;

  /// Boxes at or above this are drawn so we can see what the model sees.
  /// The report policy has its own, stricter gates.
  static const double _uiConfidenceThreshold = 0.20;

  // ===========================================================================
  // Lifecycle
  // ===========================================================================

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    _timingsCallback = _onFrameTimings;
    SchedulerBinding.instance.addTimingsCallback(_timingsCallback!);

    _ai.onResult = _onDetectionResult;

    _outcomeListener = _onUploadOutcome;
    _uploads.lastOutcome.addListener(_outcomeListener!);

    _initializeCameraAndAI();
    _startGps();
    _cacheVibratorSupport();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (_timingsCallback != null) {
      SchedulerBinding.instance.removeTimingsCallback(_timingsCallback!);
    }
    // Tear-offs of the same method are `==` but not `identical`.
    if (_ai.onResult == _onDetectionResult) {
      _ai.onResult = null;
    }
    _uploads.lastOutcome.removeListener(_outcomeListener!);
    _stopAIDetectionStream(notify: false);
    _pendingFrame = null;
    _cameraController?.dispose();
    _gpsSub?.cancel();
    // The AI worker is app-wide and stays warm — never disposed here.
    _overlay.dispose();
    _prediction.dispose();
    _diagnostics.dispose();
    super.dispose();
  }

  /// Background → stop camera + GPS (battery, heat, and avoids crashes on
  /// resume). Foreground → start again.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final controller = _cameraController;
    if (controller == null || !controller.value.isInitialized) return;

    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused) {
      _stopAIDetectionStream();
      _gpsSub?.pause();
    } else if (state == AppLifecycleState.resumed) {
      if (_gpsSub?.isPaused ?? false) _gpsSub?.resume();
      if (_isCameraInitialized && !controller.value.isStreamingImages) {
        _startFastAIDetectionStream();
      }
    }
  }

  Future<void> _cacheVibratorSupport() async {
    try {
      _hasVibrator = await Vibration.hasVibrator();
    } catch (_) {
      _hasVibrator = false;
    }
  }

  // ===========================================================================
  // GPS: continuous stream, always a fresh fix, never awaited on the hot path
  // ===========================================================================

  Future<void> _startGps() async {
    try {
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        _gpsStatus = 'GPS permission denied';
        return;
      }

      _latestFix ??= await Geolocator.getLastKnownPosition();

      final LocationSettings settings = Platform.isAndroid
          ? AndroidSettings(
              accuracy: LocationAccuracy.high,
              distanceFilter: 0,
              intervalDuration: const Duration(seconds: 1),
            )
          : const LocationSettings(
              accuracy: LocationAccuracy.high,
              distanceFilter: 0,
            );

      _gpsSub = Geolocator.getPositionStream(locationSettings: settings).listen(
        (position) {
          _latestFix = position;
          _gpsStatus = null;
          if (position.speed.isFinite &&
              position.speed > 1.0 &&
              position.heading.isFinite &&
              position.heading >= 0) {
            _lastMovingHeading = position.heading;
          }
        },
        onError: (Object e) {
          _gpsStatus = 'GPS error: $e';
          debugPrint('⚠️ GPS stream error: $e');
        },
      );
    } catch (e) {
      _gpsStatus = 'GPS unavailable: $e';
      debugPrint('⚠️ GPS start failed: $e');
    }
  }

  /// Latest fix moved forward along the heading by the fix's age (while
  /// moving) plus the camera look-ahead, so the pin lands near the pothole
  /// rather than on the car. When stopped, the last moving heading is used.
  _GeoPoint? _projectedFix() {
    final p = _latestFix;
    if (p == null) return null;
    double lat = p.latitude;
    double lon = p.longitude;
    final speed = p.speed.isFinite ? p.speed : 0.0;
    final moving = speed > 1.0 && p.heading.isFinite && p.heading >= 0;
    final heading = moving ? p.heading : _lastMovingHeading;
    String source = 'raw';
    if (heading != null) {
      final ageSeconds =
          DateTime.now().difference(p.timestamp).inMilliseconds / 1000.0;
      final travelled = moving ? speed * ageSeconds.clamp(0.0, 3.0) : 0.0;
      final distance = travelled + _lookAheadMeters;
      final rad = heading * math.pi / 180.0;
      final latRad = p.latitude * math.pi / 180.0;
      lat += (distance * math.cos(rad)) / 111320.0;
      final metersPerDegLon = 111320.0 * math.cos(latRad);
      if (metersPerDegLon.abs() > 1) {
        lon += (distance * math.sin(rad)) / metersPerDegLon;
      }
      source = moving ? 'moving' : 'stopped';
    }
    return _GeoPoint(lat, lon, source: source);
  }

  bool _isNearRecentReport(_GeoPoint fix) {
    for (final r in _recentReportFixes) {
      final d = Geolocator.distanceBetween(fix.lat, fix.lon, r.lat, r.lon);
      if (d < _dedupeRadiusMeters) return true;
    }
    return false;
  }

  // ===========================================================================
  // Camera + AI start-up
  // ===========================================================================

  Future<void> _initializeCameraAndAI() async {
    final cameras = await availableCameras();
    if (cameras.isEmpty || !mounted) return;

    final backCamera = cameras.firstWhere(
      (cam) => cam.lensDirection == CameraLensDirection.back,
      orElse: () => cameras.first,
    );

    _cameraController = CameraController(
      backCamera,
      // 720x480: enough for the model at 320–640 and for the report photo.
      // `low` would upscale; `high` only costs bandwidth.
      ResolutionPreset.medium,
      enableAudio: false,
      // Explicit format: the default differs between devices (sometimes
      // JPEG/NV21) and would break the worker's colour conversion.
      imageFormatGroup: Platform.isAndroid
          ? ImageFormatGroup.yuv420
          : ImageFormatGroup.bgra8888,
    );

    try {
      await _cameraController!.initialize();
      if (!mounted) return;
      setState(() => _isCameraInitialized = true);
    } catch (e) {
      debugPrint('❌ Camera initialization error: $e');
      return;
    }

    _updateRotation();

    // Usually already warm (pre-started in main.dart).
    await _ai.initialize();
    if (!mounted) return;
    final aiStartupError = _ai.diagnosticError;
    if (aiStartupError != null) {
      _diagnostics.value = 'AI ERROR: $aiStartupError';
      return;
    }
    _startFastAIDetectionStream();
  }

  /// Clockwise rotation that makes the sensor frame upright for the current
  /// device orientation. Sent to the worker (no-op when unchanged).
  void _updateRotation() {
    final c = _cameraController;
    if (c == null || !c.value.isInitialized) return;
    final sensor = c.description.sensorOrientation;
    final device = switch (c.value.deviceOrientation) {
      DeviceOrientation.portraitUp => 0,
      DeviceOrientation.landscapeLeft => 90,
      DeviceOrientation.portraitDown => 180,
      DeviceOrientation.landscapeRight => 270,
    };
    final rotation = c.description.lensDirection == CameraLensDirection.front
        ? (sensor + device) % 360
        : (sensor - device + 360) % 360;
    _ai.setRotation(rotation);
  }

  void _startFastAIDetectionStream() {
    final controller = _cameraController;
    if (controller == null || !controller.value.isInitialized) return;
    // Starting twice throws and doubles the load (could happen when a
    // lifecycle resume and a restart overlap).
    if (controller.value.isStreamingImages) return;

    _isDetecting = true;
    _prediction.value = 'Scanning road...';
    if (mounted) setState(() {});

    controller.startImageStream(_onCameraFrame);
  }

  void _stopAIDetectionStream({bool notify = true}) {
    _isDetecting = false;
    _pendingFrame = null;
    try {
      final controller = _cameraController;
      if (controller != null && controller.value.isStreamingImages) {
        controller.stopImageStream();
      }
    } catch (_) {
      // Stream was not running — ignore.
    }
    if (notify && mounted) setState(() {});
  }

  // ===========================================================================
  // Hot path
  // ===========================================================================

  /// Camera callback. Must stay tiny: it runs ~30×/s on the UI isolate.
  void _onCameraFrame(CameraImage image) {
    _stats.received++;
    if (!mounted || !_isDetecting) return;
    _lastFrameW = image.width;
    _lastFrameH = image.height;

    if (!_ai.isReady) {
      _stats.dropped++;
      return;
    }

    if (_ai.isFrameInFlight) {
      // Keep only the newest frame while the worker is busy.
      if (_pendingFrame != null) _stats.dropped++;
      _pendingFrame = image;
      return;
    }
    // Thermal ceiling (see maxProcessFps).
    final nowUs = DateTime.now().microsecondsSinceEpoch;
    if (nowUs - _lastDispatchUs < _minDispatchIntervalUs) {
      _stats.dropped++;
      return;
    }
    _dispatch(image);
  }

  void _dispatch(CameraImage image) {
    _updateRotation();
    if (_ai.sendFrame(image)) {
      _stats.sent++;
      _lastDispatchUs = DateTime.now().microsecondsSinceEpoch;
    } else {
      _stats.dropped++;
    }
  }

  void _onDetectionResult(DetectionResult result) {
    if (!mounted) return;

    // 1) Keep the worker busy: send the newest waiting frame right away.
    final next = _pendingFrame;
    _pendingFrame = null;
    if (next != null && _isDetecting) _dispatch(next);

    // 2) Stats.
    _stats.addResult(result);

    final error = result.error;
    if (error != null) {
      _stats.errors++;
      _diagnostics.value = 'AI ERROR: ${error.split('\n').first}';
      _lastDiagnosticLogTime = DateTime.now().millisecondsSinceEpoch;
      return;
    }

    // 3) Detections → UI.
    final detections = result.toDetectionMaps();
    final best = _pickBestPotholeDetection(
      detections,
      minConfidence: _uiConfidenceThreshold,
    );

    _prediction.value = best == null
        ? 'Clear Road'
        : (best['label'] as String? ?? 'Pothole');
    _overlay.value = _Overlay(
      detections: best == null
          ? const <Map<String, dynamic>>[]
          : <Map<String, dynamic>>[best],
      geometry: result.letterbox,
    );

    // 4) Report policy: time-based episodes, synchronous, no allocation.
    final policy = _policy ??= ReportTriggerPolicy(
      inputWidthPx: _ai.modelInfo?.inputWidth ?? 640,
    );
    int hitCount = 0;
    for (final d in detections) {
      if (((d['conf'] as double?) ?? 0.0) >= policy.tHit &&
          (d['label'] as String? ?? '').toLowerCase().contains('pothole')) {
        hitCount++;
      }
    }
    double conf = 0.0, x1 = 0.0, y1 = 0.0, x2 = 0.0, y2 = 0.0;
    if (best != null) {
      conf = best['conf'] as double;
      x1 = best['x1'] as double;
      y1 = best['y1'] as double;
      x2 = best['x2'] as double;
      y2 = best['y2'] as double;
    }
    final action = policy.onFrame(
      nowUs: result.receivedAtUs,
      frameId: result.id,
      conf: conf,
      widthNorm: x2 - x1,
      cx: (x1 + x2) / 2,
      cy: (y1 + y2) / 2,
      hitCount: hitCount,
    );
    switch (action) {
      case PolicyAction.fire:
        _fireReport(policy);
      case PolicyAction.episodeEnded:
        _onEpisodeEnded(policy);
      case PolicyAction.episodeStarted:
      case PolicyAction.none:
        break;
    }

    // 5) 2-second diagnostics line.
    _maybeLogDiagnostics(result);
  }

  Map<String, dynamic>? _pickBestPotholeDetection(
    List<Map<String, dynamic>> detections, {
    required double minConfidence,
  }) {
    Map<String, dynamic>? best;
    double bestConf = minConfidence;
    for (final d in detections) {
      final label = (d['label'] ?? '').toString().toLowerCase();
      if (!label.contains('pothole')) continue;
      final conf = (d['conf'] as num?)?.toDouble() ?? 0.0;
      if (conf < bestConf) continue;
      best = d;
      bestConf = conf;
    }
    return best;
  }

  // ===========================================================================
  // Reporting — never blocks the stream
  // ===========================================================================

  /// The policy confirmed an episode. Apply the UI-side guards (busy, floor,
  /// spatial dedupe); a suppressed fire is recorded on the episode and does
  /// NOT change policy state, so the same pothole cannot fire again until it
  /// leaves view.
  void _fireReport(ReportTriggerPolicy policy) {
    final ep = policy.episode;
    _fillGpsContext(ep);

    if (_snapshotInFlight) {
      ep.suppressMask |= SuppressReason.busy;
      return;
    }
    if (!_ai.isReady) {
      ep.suppressMask |= SuppressReason.noWorker;
      return;
    }
    final nowUs = DateTime.now().microsecondsSinceEpoch;
    if (_lastReportUs != 0 &&
        nowUs - _lastReportUs < _minReportIntervalMs * 1000) {
      ep.suppressMask |= SuppressReason.cooldown;
      return;
    }
    final fix = _projectedFix();
    ep.fixSource = fix?.source ?? 'none';
    if (fix != null && _isNearRecentReport(fix)) {
      ep.suppressMask |= SuppressReason.dedupe;
      return;
    }

    _snapshotInFlight = true;
    _lastReportUs = nowUs;
    _stats.reports++;

    if (_hasVibrator == true) {
      unawaited(Vibration.vibrate(duration: 400));
    }
    unawaited(_captureAndEnqueue(fix, ep));
  }

  void _fillGpsContext(Episode ep) {
    final p = _latestFix;
    if (p == null) return;
    ep.speedMps = p.speed;
    ep.gpsAccuracyM = p.accuracy;
    ep.headingDeg = p.heading;
  }

  void _onEpisodeEnded(ReportTriggerPolicy policy) {
    final ep = policy.episode;
    if (ep.speedMps.isNaN) _fillGpsContext(ep);
    final String result;
    if (ep.reported && ep.suppressMask == 0) {
      result = 'reported';
    } else if (ep.reported) {
      result = 'suppressed:${SuppressReason.describe(ep.suppressMask)}';
    } else {
      result = 'unconfirmed:${policy.unconfirmedReasons().join(',')}';
    }
    _episodeLog.write(policy, result: result, modelBackend: _ai.activeBackend);
  }

  Future<void> _captureAndEnqueue(_GeoPoint? fix, Episode ep) async {
    try {
      final jpeg = await _ai.requestSnapshot();
      if (jpeg == null) {
        ep.suppressMask |= SuppressReason.noSnapshot;
        debugPrint('⚠️ Report skipped: no snapshot from worker');
        return;
      }
      if (fix != null) {
        _recentReportFixes.add(fix);
        if (_recentReportFixes.length > _maxRecentFixes) {
          _recentReportFixes.removeAt(0);
        }
      } else {
        debugPrint('⚠️ Report without GPS fix (${_gpsStatus ?? 'no fix yet'})');
      }
      await _uploads.enqueue(
        PendingReport(
          jpeg: jpeg,
          capturedAt: DateTime.now(),
          latitude: fix?.lat,
          longitude: fix?.lon,
        ),
      );
    } catch (e) {
      debugPrint('❌ Report capture failed: $e');
    } finally {
      _snapshotInFlight = false;
    }
  }

  void _onUploadOutcome() {
    final outcome = _uploads.lastOutcome.value;
    if (outcome == null || !mounted) return;
    final isArabic = ApiService.currentLanguage == 'ar';
    final detail = outcome.message == null ? '' : ': ${outcome.message}';
    final (String text, Color color) = switch (outcome.kind) {
      ReportOutcomeKind.sent => (
          isArabic ? '✅ تم إرسال البلاغ!' : '✅ Report sent!',
          Colors.green,
        ),
      ReportOutcomeKind.savedOffline => (
          isArabic ? '📦 حُفظ البلاغ بدون اتصال' : '📦 Report saved offline',
          Colors.orange,
        ),
      ReportOutcomeKind.noLocation => (
          isArabic ? '📍 حُفظ البلاغ بدون موقع' : '📍 Saved without location',
          Colors.orange,
        ),
      ReportOutcomeKind.failed => (
          isArabic ? '❌ فشل الإرسال$detail' : '❌ Failed to send$detail',
          Colors.red,
        ),
    };
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(text),
        backgroundColor: color,
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 2),
      ),
    );
  }

  // ===========================================================================
  // Diagnostics
  // ===========================================================================

  void _onFrameTimings(List<FrameTiming> timings) {
    for (final t in timings) {
      _stats.uiFrames++;
      if (t.totalSpan.inMicroseconds > 16700) _stats.jank++;
    }
  }

  void _maybeLogDiagnostics(DetectionResult result) {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (_lastDiagnosticLogTime == 0) {
      _lastDiagnosticLogTime = now;
      return;
    }
    final windowMs = now - _lastDiagnosticLogTime;
    if (windowMs < 2000) return;
    _lastDiagnosticLogTime = now;

    final policy = _policy;
    final episodeInfo = policy == null
        ? null
        : 'ep:${policy.state.name} hit:${policy.episode.hitMs.round()}ms '
            'peak:${policy.episode.peak.toStringAsFixed(2)}';
    final line = _stats.summarize(
      windowMs: windowMs,
      backend: result.backend,
      frameSize: '${_lastFrameW}x$_lastFrameH',
      maxScore: result.maxScore,
      boxes: result.count,
      gpsStatus: _gpsStatus,
      episode: episodeInfo,
    );
    _diagnostics.value = line;
    debugPrint('🔎 $line');
    _stats.resetWindow();
  }

  /// Bench harness: long-press the AI panel to cycle model asset × backend.
  /// Order: (asset0, GPU) → (asset0, CPU) → (asset1, GPU) → …
  Future<void> _cycleBenchConfig() async {
    final assets = TFLiteService.benchModelAssets;
    final idx = math.max(0, assets.indexOf(_ai.modelAsset));
    final String nextAsset;
    final bool nextGpu;
    if (_ai.preferGpu) {
      nextAsset = assets[idx];
      nextGpu = false;
    } else {
      nextAsset = assets[(idx + 1) % assets.length];
      nextGpu = true;
    }

    _stopAIDetectionStream();
    _diagnostics.value =
        'AI | restarting → ${nextAsset.split('/').last} '
        '(${nextGpu ? 'GPU first' : 'CPU only'})…';
    await _ai.restart(modelAsset: nextAsset, preferGpu: nextGpu);
    if (!mounted) return;
    _policy = null; // model input size may differ
    _stats.resetWindow();
    _lastDiagnosticLogTime = 0;
    final error = _ai.diagnosticError;
    if (error != null) {
      _diagnostics.value = 'AI ERROR: $error';
      return;
    }
    _startFastAIDetectionStream();
  }

  String _getArabicLabel(String englishLabel) {
    if (englishLabel.toLowerCase().contains('pothole')) return 'حفرة';
    return englishLabel;
  }

  // ===========================================================================
  // UI
  // ===========================================================================

  @override
  Widget build(BuildContext context) {
    final isArabic = ApiService.currentLanguage == 'ar';

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          if (_isCameraInitialized && _cameraController != null)
            Stack(
              fit: StackFit.expand,
              children: [
                // The preview widget rotates itself to the device
                // orientation, so the box we fit it into must follow the
                // same orientation or the boxes drawn on top will not line
                // up. previewSize is reported in sensor (landscape) terms.
                Positioned.fill(
                  child: ValueListenableBuilder<CameraValue>(
                    valueListenable: _cameraController!,
                    builder: (_, value, _) {
                      final size = value.previewSize;
                      if (size == null) return const SizedBox.shrink();
                      final landscape = value.deviceOrientation ==
                              DeviceOrientation.landscapeLeft ||
                          value.deviceOrientation ==
                              DeviceOrientation.landscapeRight;
                      return ClipRect(
                        child: FittedBox(
                          fit: BoxFit.cover,
                          child: SizedBox(
                            width: landscape ? size.width : size.height,
                            height: landscape ? size.height : size.width,
                            child: CameraPreview(_cameraController!),
                          ),
                        ),
                      );
                    },
                  ),
                ),
                // Repaints only when the boxes change.
                Positioned.fill(
                  child: ValueListenableBuilder<_Overlay>(
                    valueListenable: _overlay,
                    builder: (_, overlay, _) => CustomPaint(
                      size: Size.infinite,
                      painter: BoundingBoxPainter(
                        detections: overlay.detections,
                        geometry: overlay.geometry,
                      ),
                    ),
                  ),
                ),
              ],
            )
          else
            Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const CircularProgressIndicator(color: Color(0xFFFFD700)),
                  const SizedBox(height: 16),
                  Text(
                    isArabic
                        ? 'جاري تهيئة الكاميرا الذكية...'
                        : 'Initializing High-Speed Dashcam...',
                    style: const TextStyle(color: Colors.white54),
                  ),
                ],
              ),
            ),

          _buildTopBar(isArabic),
          _buildDiagnosticsPanel(),
          _buildUploadPill(isArabic),
          _buildHud(isArabic),
        ],
      ),
    );
  }

  Widget _buildTopBar(bool isArabic) {
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: Container(
        height: 120,
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Colors.black.withValues(alpha: 0.88),
              Colors.transparent,
            ],
          ),
        ),
        padding: const EdgeInsets.only(top: 50, left: 16, right: 16),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            IconButton(
              icon: const Icon(Icons.arrow_back_ios,
                  color: Colors.white, size: 28),
              onPressed: () => Navigator.pop(context),
            ),
            if (_isDetecting)
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(30),
                  border:
                      Border.all(color: Colors.white.withValues(alpha: 0.14)),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 10,
                      height: 10,
                      decoration: const BoxDecoration(
                        color: Colors.redAccent,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      isArabic ? 'تحليل مباشر' : 'LIVE AI',
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 1.2,
                      ),
                    ),
                  ],
                ),
              ),
            const SizedBox(width: 48),
          ],
        ),
      ),
    );
  }

  /// On-device log: backend chosen, GPU/CPU attempts, and the 2-second
  /// performance line. Long-press to cycle model/backend (bench harness).
  Widget _buildDiagnosticsPanel() {
    return Positioned(
      top: 126,
      left: 16,
      right: 16,
      child: GestureDetector(
        onLongPress: _cycleBenchConfig,
        child: ValueListenableBuilder<List<String>>(
          valueListenable: _ai.diagnosticEvents,
          builder: (_, events, _) => ValueListenableBuilder<String>(
            valueListenable: _diagnostics,
            builder: (_, summary, _) {
              final hasError = summary.startsWith('AI ERROR') ||
                  events.any((event) => event.contains('ERROR'));
              return Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
                decoration: BoxDecoration(
                  color: hasError
                      ? Colors.red.withValues(alpha: 0.86)
                      : Colors.black.withValues(alpha: 0.74),
                  borderRadius: BorderRadius.circular(10),
                  border:
                      Border.all(color: Colors.white.withValues(alpha: 0.18)),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Icon(
                          hasError
                              ? Icons.error_outline_rounded
                              : Icons.memory_rounded,
                          color:
                              hasError ? Colors.white : const Color(0xFFFFD700),
                          size: 16,
                        ),
                        const SizedBox(width: 6),
                        const Expanded(
                          child: Text(
                            'AI device log — long-press to switch model/backend',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 5),
                    Text(
                      summary,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.left,
                      textDirection: TextDirection.ltr,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 11,
                        fontFamily: 'monospace',
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    if (events.isNotEmpty) ...[
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 6),
                        child: Divider(height: 1, color: Colors.white30),
                      ),
                      for (final event in events)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 1),
                          child: Text(
                            event,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            textDirection: TextDirection.ltr,
                            style: const TextStyle(
                              color: Colors.white70,
                              fontFamily: 'monospace',
                              fontSize: 10,
                              height: 1.2,
                            ),
                          ),
                        ),
                    ],
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  /// Shows how many reports are queued/uploading. Detection keeps running.
  Widget _buildUploadPill(bool isArabic) {
    return ValueListenableBuilder<int>(
      valueListenable: _uploads.pending,
      builder: (_, pending, _) {
        if (pending <= 0) return const SizedBox.shrink();
        return Positioned(
          right: 24,
          top: 268,
          child: Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.black54,
              borderRadius: BorderRadius.circular(30),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                      color: Colors.orange, strokeWidth: 2),
                ),
                const SizedBox(width: 8),
                Text(
                  isArabic
                      ? 'جاري الرفع ($pending)...'
                      : 'Uploading ($pending)...',
                  style: const TextStyle(color: Colors.white, fontSize: 12),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// HUD. No BackdropFilter: a blur over a live preview is re-rasterised on
  /// every camera frame and was one of the most expensive things on screen.
  Widget _buildHud(bool isArabic) {
    return Positioned(
      bottom: 40,
      left: 24,
      right: 24,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(24),
        child: ValueListenableBuilder<String>(
          valueListenable: _prediction,
          builder: (_, prediction, _) {
            final dmg = prediction.toLowerCase();
            final isHazardDetected = dmg.contains('pothole');
            final hudColor =
                isHazardDetected ? Colors.redAccent : const Color(0xFFFFD700);
            final hudIcon =
                isHazardDetected ? Icons.warning_amber_rounded : Icons.radar;

            String displayText = prediction;
            if (prediction.isNotEmpty && prediction != 'Scanning road...') {
              displayText = prediction[0].toUpperCase() +
                  prediction.substring(1).toLowerCase();
            }
            if (isArabic) {
              displayText = isHazardDetected
                  ? _getArabicLabel(prediction)
                  : 'جاري مسح الطريق...';
            }

            return AnimatedContainer(
              duration: const Duration(milliseconds: 300),
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: isHazardDetected
                      ? [
                          Colors.red.withValues(alpha: 0.55),
                          Colors.black.withValues(alpha: 0.88),
                        ]
                      : [
                          const Color(0xFF1E1E1E).withValues(alpha: 0.9),
                          Colors.black.withValues(alpha: 0.8),
                        ],
                ),
                borderRadius: BorderRadius.circular(24),
                border: Border.all(
                    color: hudColor.withValues(alpha: 0.55), width: 1.8),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(hudIcon, color: hudColor, size: 34),
                      const SizedBox(width: 10),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 6),
                        decoration: BoxDecoration(
                          color: hudColor.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(999),
                          border: Border.all(
                              color: hudColor.withValues(alpha: 0.35)),
                        ),
                        child: Text(
                          isArabic ? 'مباشر' : 'LIVE',
                          style: TextStyle(
                            color: hudColor,
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                            letterSpacing: 1.1,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Text(
                    displayText,
                    style: TextStyle(
                        color: hudColor,
                        fontSize: 22,
                        fontWeight: FontWeight.bold),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    isArabic
                        ? 'المعالجة تعمل في الخلفية — البلاغات تُرفع بدون توقف الكشف'
                        : 'Background processing — reports upload without pausing detection',
                    style:
                        const TextStyle(color: Colors.white54, fontSize: 13),
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

// =============================================================================
// Helpers
// =============================================================================

/// What the painter draws: the current boxes plus the letterbox geometry
/// needed to place them on the preview. Value-equal so repeated "clear road"
/// frames do not trigger repaints.
class _Overlay {
  const _Overlay({required this.detections, required this.geometry});
  const _Overlay.empty()
      : detections = const <Map<String, dynamic>>[],
        geometry = null;

  final List<Map<String, dynamic>> detections;
  final LetterboxGeometry? geometry;

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! _Overlay) return false;
    if (other.geometry != geometry) return false;
    if (other.detections.length != detections.length) return false;
    for (int i = 0; i < detections.length; i++) {
      final a = detections[i], b = other.detections[i];
      if (a['x1'] != b['x1'] ||
          a['y1'] != b['y1'] ||
          a['x2'] != b['x2'] ||
          a['y2'] != b['y2'] ||
          a['conf'] != b['conf'] ||
          a['label'] != b['label']) {
        return false;
      }
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(detections.length, geometry);
}

class _GeoPoint {
  const _GeoPoint(this.lat, this.lon, {this.source = 'raw'});
  final double lat;
  final double lon;

  /// `moving` (projected by speed and heading), `stopped` (look-ahead along
  /// the last moving heading) or `raw` (no heading known).
  final String source;
}

/// Per-window counters behind the 2-second diagnostics line. Only ints are
/// touched per frame; formatting happens twice a second at most.
class _FrameStats {
  int received = 0;
  int sent = 0;
  int dropped = 0;
  int processed = 0;
  int errors = 0;
  int reports = 0;
  int sumPreUs = 0;
  int sumSetUs = 0;
  int sumInvUs = 0;
  int sumPostUs = 0;
  int sumTotalUs = 0;
  int sumRoundTripUs = 0;
  int uiFrames = 0;
  int jank = 0;

  void addResult(DetectionResult r) {
    processed++;
    sumPreUs += r.preprocessUs;
    sumSetUs += r.setInputUs;
    sumInvUs += r.invokeUs;
    sumPostUs += r.postprocessUs;
    sumTotalUs += r.totalUs;
    sumRoundTripUs += r.roundTripUs;
  }

  void resetWindow() {
    received = 0;
    sent = 0;
    dropped = 0;
    processed = 0;
    errors = 0;
    reports = 0;
    sumPreUs = 0;
    sumSetUs = 0;
    sumInvUs = 0;
    sumPostUs = 0;
    sumTotalUs = 0;
    sumRoundTripUs = 0;
    uiFrames = 0;
    jank = 0;
  }

  String summarize({
    required int windowMs,
    required String backend,
    required String frameSize,
    required double maxScore,
    required int boxes,
    String? gpsStatus,
    String? episode,
  }) {
    final seconds = windowMs <= 0 ? 1.0 : windowMs / 1000.0;
    final procFps = processed / seconds;
    final camFps = received / seconds;
    final dropPct = received == 0 ? 0 : (dropped * 100 / received).round();
    int ms(int sumUs) => processed == 0 ? 0 : (sumUs / processed / 1000).round();

    final buffer = StringBuffer()
      ..write('AI $backend | proc ${procFps.toStringAsFixed(1)} fps ')
      ..write('(cam ${camFps.toStringAsFixed(1)}, drop $dropPct%) | ')
      ..write('pre ${ms(sumPreUs)} set ${ms(sumSetUs)} inv ${ms(sumInvUs)} ')
      ..write('post ${ms(sumPostUs)} | total ${ms(sumTotalUs)} ')
      ..write('rt ${ms(sumRoundTripUs)} ms | jank $jank/$uiFrames | ')
      ..write('$frameSize | score ${maxScore.toStringAsFixed(2)} boxes $boxes');
    if (episode != null) buffer.write(' | $episode');
    if (reports > 0) buffer.write(' | reports $reports');
    if (errors > 0) buffer.write(' | errors $errors');
    if (gpsStatus != null) buffer.write(' | $gpsStatus');
    return buffer.toString();
  }
}
