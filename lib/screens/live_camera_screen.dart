import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:geolocator/geolocator.dart';
import 'package:image/image.dart' as img;
import '../services/api_service.dart';
import '../services/tflite_service.dart';
import '../widgets/bounding_box_painter.dart';
import 'package:vibration/vibration.dart';

class LiveCameraScreen extends StatefulWidget {
  const LiveCameraScreen({super.key});

  @override
  State<LiveCameraScreen> createState() => _LiveCameraScreenState();
}

class _LiveCameraScreenState extends State<LiveCameraScreen> {
  static const bool _allowTakePictureFallback = false;

  CameraController? _cameraController;
  final TFLiteService _tfliteService = TFLiteService();

  bool _isCameraInitialized = false;
  bool _isDetecting = false;

  List<Map<String, dynamic>> _detections = [];

  bool _isProcessingFrame = false;
  int _lastFrameTime = 0;
  final int _fpsIntervalMs = 333;

  String _currentPrediction = 'Scanning road...';
  AiModelMode _activeModelMode = AiModelMode.float16;
  bool _isSwitchingModel = false;

  bool _isUploadingReport = false;
  bool _isReporting = false;
  DateTime? _lastReportTime;
  final int _cooldownSeconds = 6;
  final int _duplicateReportWindowSeconds = 30;
  final double _duplicateReportDistanceMeters = 20.0;

  final double _uiConfidenceThreshold = 0.10;
  final double _reportConfidenceThreshold = 0.22;
  final double _reportMinBoxArea = 0.018;
  final int _requiredConsecutivePotholeFrames = 3;
  int _potholeFrameStreak = 0;
  Position? _lastValidPosition;

  StreamSubscription<Position>? _positionStreamSub;
  Position? _lastReportedPosition;
  DateTime? _lastReportedAt;
  DateTime? _lastLocationRefreshAt;

  @override
  void initState() {
    super.initState();
    unawaited(_startLocationStream());
    _initializeCameraAndAI();
  }

  bool _isInvalidPosition(Position p) {
    return p.latitude == 0.0 && p.longitude == 0.0;
  }

  Future<void> _startLocationStream() async {
    try {
      final enabled = await Geolocator.isLocationServiceEnabled();
      if (!enabled) return;

      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }

      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        return;
      }

      const settings = LocationSettings(
        accuracy: LocationAccuracy.medium,
        distanceFilter: 8,
      );

      _positionStreamSub =
          Geolocator.getPositionStream(locationSettings: settings).listen((
            position,
          ) {
            if (_isInvalidPosition(position)) return;
            _lastValidPosition = position;
          });
    } catch (_) {}
  }

  Future<void> _refreshLocationCache() async {
    try {
      const settings = LocationSettings(accuracy: LocationAccuracy.medium);
      final position = await Geolocator.getCurrentPosition(
        locationSettings: settings,
      ).timeout(const Duration(seconds: 3));

      if (_isInvalidPosition(position)) return;
      _lastValidPosition = position;
    } catch (_) {}
  }

  Future<Position> _resolveReportPosition() async {
    final now = DateTime.now();
    final cached = _lastValidPosition;
    final shouldRefresh =
        _lastLocationRefreshAt == null ||
        now.difference(_lastLocationRefreshAt!).inSeconds >= 6;

    if (cached != null && !_isInvalidPosition(cached)) {
      if (shouldRefresh) {
        _lastLocationRefreshAt = now;
        unawaited(_refreshLocationCache());
      }
      return cached;
    }

    _lastLocationRefreshAt = now;
    try {
      const settings = LocationSettings(accuracy: LocationAccuracy.high);
      final live =
          await Geolocator.getCurrentPosition(
            locationSettings: settings,
          ).timeout(
            const Duration(seconds: 4),
            onTimeout: () => throw TimeoutException('GPS timeout (>4s)'),
          );
      if (_isInvalidPosition(live)) {
        throw Exception('Invalid GPS location: coordinates are (0,0)');
      }
      _lastValidPosition = live;
      return live;
    } catch (_) {
      final fallback = await Geolocator.getLastKnownPosition();
      if (fallback != null && !_isInvalidPosition(fallback)) {
        _lastValidPosition = fallback;
        return fallback;
      }
      rethrow;
    }
  }

  bool _isDuplicateNearbyReport(Position position) {
    if (_lastReportedPosition == null || _lastReportedAt == null) return false;

    final seconds = DateTime.now().difference(_lastReportedAt!).inSeconds;
    if (seconds > _duplicateReportWindowSeconds) return false;

    final distance = Geolocator.distanceBetween(
      _lastReportedPosition!.latitude,
      _lastReportedPosition!.longitude,
      position.latitude,
      position.longitude,
    );

    return distance < _duplicateReportDistanceMeters;
  }

  void _markReportSent(Position position) {
    _lastReportedPosition = position;
    _lastReportedAt = DateTime.now();
  }

  Future<void> _initializeCameraAndAI() async {
    await _tfliteService.initializeModel();
    if (_tfliteService.activeModelMode != AiModelMode.float16) {
      await _tfliteService.switchModelMode(AiModelMode.float16);
    }
    _activeModelMode = _tfliteService.activeModelMode;

    final cameras = await availableCameras();
    if (cameras.isEmpty) return;

    final backCamera = cameras.firstWhere(
      (cam) => cam.lensDirection == CameraLensDirection.back,
      orElse: () => cameras.first,
    );

    _cameraController = CameraController(
      backCamera,
      ResolutionPreset.low,
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.yuv420,
    );

    try {
      await _cameraController!.initialize();
      if (!mounted) return;

      setState(() => _isCameraInitialized = true);
      _startFastAIDetectionStream();
    } catch (_) {}
  }

  void _startFastAIDetectionStream() {
    if (_cameraController == null || !_cameraController!.value.isInitialized) {
      return;
    }

    setState(() {
      _isDetecting = true;
      _currentPrediction = "Scanning road...";
    });

    _cameraController!.startImageStream((CameraImage image) async {
      if (_isReporting || _isUploadingReport) return;
      if (_isSwitchingModel) return;
      if (_isProcessingFrame || !mounted) return;
      if (image.format.group != ImageFormatGroup.yuv420) return;

      int currentTime = DateTime.now().millisecondsSinceEpoch;
      if (currentTime - _lastFrameTime < _fpsIntervalMs) return;

      _isProcessingFrame = true;
      _lastFrameTime = currentTime;

      try {
        final result = await _tfliteService.predictFrameWithBoxes(image);
        final detections = _normalizeDetections(result['detections']);
        final uiPothole = _pickBestPotholeDetection(
          detections,
          minConfidence: _uiConfidenceThreshold,
        );
        final reportPothole = _pickBestPotholeDetection(
          detections,
          minConfidence: _reportConfidenceThreshold,
          minBoxArea: _reportMinBoxArea,
        );
        String detectedDamage = uiPothole == null
            ? 'Clear Road'
            : (uiPothole['label'] as String? ?? 'Pothole');
        final nextDetections = uiPothole == null
            ? <Map<String, dynamic>>[]
            : [uiPothole];

        if (mounted && _shouldUpdateUi(detectedDamage, nextDetections)) {
          setState(() {
            _currentPrediction = detectedDamage;
            _detections = nextDetections;
          });
        }

        if (reportPothole != null) {
          _potholeFrameStreak++;
        } else {
          _potholeFrameStreak = 0;
        }

        bool isTemporalConfirmed =
            _potholeFrameStreak >= _requiredConsecutivePotholeFrames;

        if (isTemporalConfirmed && !_isUploadingReport && !_isReporting) {
          bool canReport =
              _lastReportTime == null ||
              DateTime.now().difference(_lastReportTime!).inSeconds >
                  _cooldownSeconds;

          if (canReport) {
            
              Vibration.vibrate(duration: 400);
            

            _lastReportTime = DateTime.now();
            _isReporting = true;
            _potholeFrameStreak = 0;

            _stopAIDetectionStream(updateUi: false);
            unawaited(_autoSubmitReport(sourceFrame: image));
          }
        }
      } catch (_) {
      } finally {
        _isProcessingFrame = false;
      }
    });
  }

  Future<void> _switchModelMode(AiModelMode nextMode) async {
    if (_isSwitchingModel) return;
    if (nextMode == _activeModelMode) return;

    if (mounted) {
      setState(() {
        _isSwitchingModel = true;
      });
    } else {
      _isSwitchingModel = true;
    }

    _isProcessingFrame = false;
    _stopAIDetectionStream(updateUi: false);

    try {
      final appliedMode = await _tfliteService.switchModelMode(nextMode);
      final exactModeApplied = appliedMode == nextMode;

      if (mounted) {
        setState(() {
          _activeModelMode = appliedMode;
          _currentPrediction = 'Scanning road...';
          _detections = <Map<String, dynamic>>[];
          _potholeFrameStreak = 0;
        });

        final isArabic = ApiService.currentLanguage == 'ar';
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              exactModeApplied
                  ? (isArabic
                        ? '✅ تم التبديل إلى ${TFLiteService.modeLabel(appliedMode)}'
                        : '✅ Switched to ${TFLiteService.modeLabel(appliedMode)}')
                  : (isArabic
                        ? '⚠️ الوضع المطلوب غير متوفر. تم استخدام ${TFLiteService.modeLabel(appliedMode)}'
                        : '⚠️ Requested mode unavailable. Using ${TFLiteService.modeLabel(appliedMode)}'),
            ),
            behavior: SnackBarBehavior.floating,
            duration: const Duration(seconds: 2),
          ),
        );
      } else {
        _activeModelMode = appliedMode;
      }
    } catch (e) {
      if (mounted) {
        final isArabic = ApiService.currentLanguage == 'ar';
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              isArabic
                  ? '❌ فشل تبديل وضع الذكاء الاصطناعي: $e'
                  : '❌ Failed to switch AI mode: $e',
            ),
            backgroundColor: Colors.red,
            behavior: SnackBarBehavior.floating,
            duration: const Duration(seconds: 3),
          ),
        );
      }
    } finally {
      if (mounted &&
          _cameraController != null &&
          _cameraController!.value.isInitialized &&
          !_cameraController!.value.isStreamingImages) {
        _startFastAIDetectionStream();
      }

      if (mounted) {
        setState(() {
          _isSwitchingModel = false;
        });
      } else {
        _isSwitchingModel = false;
      }
    }
  }

  Future<void> _autoSubmitReport({CameraImage? sourceFrame}) async {
    if (mounted) {
      setState(() => _isUploadingReport = true);
    } else {
      _isUploadingReport = true;
    }
    final isArabic = ApiService.currentLanguage == 'ar';

    try {
      // Get GPS location with timeout (fail gracefully if unavailable)
      Position position;
      try {
        position = await _resolveReportPosition();
      } catch (e) {
        String gpsError = 'GPS Error: ';
        if (e.toString().contains('Location services are disabled')) {
          gpsError += 'Location services disabled on device';
        } else if (e.toString().contains('Permission')) {
          gpsError += 'Location permission denied by user';
        } else if (e.toString().contains('timeout')) {
          gpsError += 'GPS took too long (>4s)';
        } else {
          gpsError += e.toString();
        }

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                isArabic
                    ? '❌ لا يمكن إرسال البلاغ بدون موقع GPS صالح'
                    : '❌ Cannot send report without valid GPS location ($gpsError)',
              ),
              backgroundColor: Colors.red,
              behavior: SnackBarBehavior.floating,
              duration: const Duration(seconds: 3),
            ),
          );
        }

        throw Exception(gpsError);
      }

      if (_isDuplicateNearbyReport(position)) {
        return;
      }

      if (_cameraController == null ||
          !_cameraController!.value.isInitialized) {
        throw Exception('Camera Error: Camera controller not initialized');
      }

      XFile? capturedPhoto;
      try {
        final captured = await _capturePhotoForReport(sourceFrame: sourceFrame);
        capturedPhoto = captured;
      } catch (e) {
        String photoError = 'Photo Capture Error: ';
        if (e.toString().contains('timeout')) {
          photoError += 'Camera took >5s to capture photo';
        } else if (e.toString().contains('camera')) {
          photoError += 'Camera hardware error or not ready';
        } else {
          photoError += e.toString();
        }
        throw Exception(photoError);
      }

      // Force report type to pothole only.
      int typeId = 1;

      bool success =
          await ApiService.submitReport(
            photo: capturedPhoto,
            latitude: position.latitude,
            longitude: position.longitude,
            typeId: typeId,
          ).timeout(
            const Duration(seconds: 30),
            onTimeout: () =>
                throw TimeoutException('API request timeout (>30s)'),
          );
      if (success) _markReportSent(position);

      if (mounted) {
        // success includes normal create (200/201) and duplicate hazard accepted as success (409)
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              success
                  ? (isArabic ? '✅ تم إرسال البلاغ!' : '✅ Report sent!')
                  : (isArabic ? '❌ فشل الإرسال' : '❌ Failed to send'),
            ),
            backgroundColor: success ? Colors.green : Colors.red,
            behavior: SnackBarBehavior.floating,
            duration: const Duration(seconds: 2),
          ),
        );
      }
    } catch (e) {
      String errorMsg = e.toString();

      // Provide more specific error details
      String displayError = errorMsg;
      if (errorMsg.contains('Connection refused')) {
        displayError =
            'Network Error: Cannot connect to server - check internet connection';
      } else if (errorMsg.contains('timeout')) {
        displayError =
            'Timeout Error: Request took too long - network may be slow';
      } else if (errorMsg.contains('Socket')) {
        displayError = 'Network Error: Internet connection lost';
      } else if (errorMsg.contains('Camera')) {
        displayError = 'Camera Error: Unable to capture photo';
      } else if (errorMsg.contains('GPS')) {
        displayError = 'Location Error: GPS not available';
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              isArabic ? '❌ خطأ: $errorMsg' : '❌ Error: $displayError',
            ),
            backgroundColor: Colors.red,
            behavior: SnackBarBehavior.floating,
            duration: const Duration(seconds: 3),
          ),
        );
      }
    } finally {
  _isReporting = false;
  if (mounted) setState(() => _isUploadingReport = false);
  _isUploadingReport = false;
  // أعد تشغيل الـ stream بعد الإرسال
  if (mounted && _cameraController != null && 
      _cameraController!.value.isInitialized &&
      !_cameraController!.value.isStreamingImages) {
    _startFastAIDetectionStream();
  }
}

  Future<XFile> _buildReportPhotoFromFrame(CameraImage frame) async {
    final jpgBytes = _cameraImageToJpegBytes(
      frame,
      targetWidth: 192,
      quality: 60,
    );
    if (jpgBytes == null || jpgBytes.isEmpty) {
      throw Exception('Photo Capture Error: Cannot convert frame to JPEG');
    }

    final tempFile = File(
      '${Directory.systemTemp.path}${Platform.pathSeparator}rased_auto_${DateTime.now().millisecondsSinceEpoch}.jpg',
    );
    await tempFile.writeAsBytes(jpgBytes, flush: true);
    return XFile(tempFile.path);
  }

  Future<XFile> _capturePhotoForReport({CameraImage? sourceFrame}) async {
    if (sourceFrame != null) {
      return _buildReportPhotoFromFrame(sourceFrame);
    }

    if (!_allowTakePictureFallback) {
      throw Exception(
        'Photo Capture Error: No source frame available and takePicture fallback disabled',
      );
    }

    return _cameraController!.takePicture().timeout(
      const Duration(seconds: 5),
      onTimeout: () => throw TimeoutException('Photo capture timeout'),
    );
  }

  Uint8List? _cameraImageToJpegBytes(
    CameraImage cameraImage, {
    required int targetWidth,
    required int quality,
  }) {
    final width = cameraImage.width;
    final height = cameraImage.height;
    final outputWidth = targetWidth > width ? width : targetWidth;
    final outputHeight = ((outputWidth * height) / width)
        .round()
        .clamp(1, height)
        .toInt();
    img.Image? rgb;

    if (cameraImage.format.group == ImageFormatGroup.yuv420) {
      if (cameraImage.planes.length < 3) return null;

      final plane0 = cameraImage.planes[0].bytes;
      final plane1 = cameraImage.planes[1].bytes;
      final plane2 = cameraImage.planes[2].bytes;
      final yRowStride = cameraImage.planes[0].bytesPerRow;
      final uvRowStride = cameraImage.planes[1].bytesPerRow;
      final uvPixelStride = cameraImage.planes[1].bytesPerPixel ?? 0;
      if (uvPixelStride == 0) return null;

      rgb = img.Image(width: outputWidth, height: outputHeight);
      for (int y = 0; y < outputHeight; y++) {
        final srcY = ((y * height) / outputHeight).floor().clamp(0, height - 1);
        final yRow = srcY * yRowStride;
        final uvRow = uvRowStride * (srcY ~/ 2);
        for (int x = 0; x < outputWidth; x++) {
          final srcX = ((x * width) / outputWidth).floor().clamp(0, width - 1);
          final uvIndex = uvPixelStride * (srcX ~/ 2) + uvRow;
          final index = yRow + srcX;

          final yp = plane0[index];
          final up = plane1[uvIndex];
          final vp = plane2[uvIndex];

          final r = (yp + vp * 1436 / 1024 - 179).round().clamp(0, 255);
          final g = (yp - up * 46549 / 131072 + 44 - vp * 93604 / 131072 + 91)
              .round()
              .clamp(0, 255);
          final b = (yp + up * 1814 / 1024 - 227).round().clamp(0, 255);
          rgb.setPixelRgb(x, y, r, g, b);
        }
      }
    } else if (cameraImage.format.group == ImageFormatGroup.bgra8888) {
      final plane0 = cameraImage.planes[0].bytes;
      final full = img.Image.fromBytes(
        width: width,
        height: height,
        bytes: plane0.buffer,
        order: img.ChannelOrder.bgra,
      );

      rgb = outputWidth == width
          ? full
          : img.copyResize(
              full,
              width: outputWidth,
              height: outputHeight,
              interpolation: img.Interpolation.average,
            );
    }

    if (rgb == null) return null;
    return Uint8List.fromList(img.encodeJpg(rgb, quality: quality));
  }

  List<Map<String, dynamic>> _normalizeDetections(dynamic rawDetections) {
    if (rawDetections is! List) return [];

    final normalized = <Map<String, dynamic>>[];
    for (final item in rawDetections) {
      if (item is! Map) continue;

      final map = Map<String, dynamic>.from(item);
      normalized.add({
        'x1': (map['x1'] as num?)?.toDouble() ?? 0.0,
        'y1': (map['y1'] as num?)?.toDouble() ?? 0.0,
        'x2': (map['x2'] as num?)?.toDouble() ?? 0.0,
        'y2': (map['y2'] as num?)?.toDouble() ?? 0.0,
        'conf': (map['conf'] as num?)?.toDouble() ?? 0.0,
        'label': (map['label'] ?? '').toString(),
      });
    }
    return normalized;
  }

  bool _shouldUpdateUi(
    String nextPrediction,
    List<Map<String, dynamic>> nextDetections,
  ) {
    if (_currentPrediction != nextPrediction) return true;
    if (_detections.length != nextDetections.length) return true;
    if (_detections.isEmpty) return false;

    final prev = _detections.first;
    final next = nextDetections.first;

    final prevLabel = (prev['label'] ?? '').toString();
    final nextLabel = (next['label'] ?? '').toString();
    if (prevLabel != nextLabel) return true;

    final prevConf = (prev['conf'] as num?)?.toDouble() ?? 0.0;
    final nextConf = (next['conf'] as num?)?.toDouble() ?? 0.0;

    // Ignore tiny confidence jitter to reduce paint churn on mobile GPUs.
    return (prevConf - nextConf).abs() > 0.03;
  }

  Map<String, dynamic>? _pickBestPotholeDetection(
    List<Map<String, dynamic>> detections, {
    required double minConfidence,
    double minBoxArea = 0.0,
  }) {
    Map<String, dynamic>? best;
    double bestConf = minConfidence;

    for (final d in detections) {
      final label = (d['label'] ?? '').toString().toLowerCase();
      final conf = (d['conf'] as num?)?.toDouble() ?? 0.0;
      if (!_isRoadDamageLabel(label)) continue;
      if (conf < minConfidence) continue;

      final x1 = (d['x1'] as num?)?.toDouble() ?? 0.0;
      final y1 = (d['y1'] as num?)?.toDouble() ?? 0.0;
      final x2 = (d['x2'] as num?)?.toDouble() ?? 0.0;
      final y2 = (d['y2'] as num?)?.toDouble() ?? 0.0;
      final boxArea = (x2 - x1).abs() * (y2 - y1).abs();
      if (boxArea < minBoxArea) continue;

      if (best == null || conf > bestConf) {
        best = d;
        bestConf = conf;
      }
    }

    return best;
  }

  bool _isRoadDamageLabel(String rawLabel) {
    final label = rawLabel
        .toLowerCase()
        .replaceAll('-', '_')
        .replaceAll(' ', '_');
    return label.contains('pothole') ||
        label.contains('broken_manhole') ||
        label.contains('manhole') ||
        label.contains('crack');
  }

  void _stopAIDetectionStream({bool updateUi = true}) {
    try {
      _cameraController?.stopImageStream();
    } catch (_) {
      // Stream was not active — safe to ignore
    }
    if (updateUi && mounted) {
      setState(() {
        _isDetecting = false;
      });
    }
  }

  @override
  void dispose() {
    _stopAIDetectionStream(updateUi: false);
    _positionStreamSub?.cancel();
    _cameraController?.dispose();
    super.dispose();
  }

  // Helper method to properly translate AI labels to Arabic for the UI
  String _getArabicLabel(String englishLabel) {
    String lower = englishLabel.toLowerCase();
    if (lower.contains('pothole')) return 'حفرة';
    return englishLabel;
  }

  Widget _buildModelModeSwitcher(bool isArabic) {
    return PopupMenuButton<AiModelMode>(
      enabled: !_isSwitchingModel,
      tooltip: isArabic ? 'وضع النموذج' : 'Model mode',
      color: const Color(0xFF1F1F1F),
      onSelected: (AiModelMode mode) {
        unawaited(_switchModelMode(mode));
      },
      itemBuilder: (BuildContext context) {
        return <PopupMenuEntry<AiModelMode>>[
          PopupMenuItem<AiModelMode>(
            value: AiModelMode.float32,
            child: Text(isArabic ? 'Float32 (أدق)' : 'Float32 (more accurate)'),
          ),
          PopupMenuItem<AiModelMode>(
            value: AiModelMode.float16,
            child: Text(isArabic ? 'Float16 (أسرع)' : 'Float16 (faster)'),
          ),
        ];
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: Colors.white.withValues(alpha: 0.14)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _isSwitchingModel
                ? const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.orange,
                    ),
                  )
                : const Icon(Icons.memory, color: Colors.white70, size: 15),
            const SizedBox(width: 6),
            Text(
              TFLiteService.modeShortLabel(_activeModelMode),
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.5,
              ),
            ),
            const SizedBox(width: 2),
            const Icon(Icons.arrow_drop_down, color: Colors.white70),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isArabic = ApiService.currentLanguage == 'ar';

    // UI highlights only pothole as hazard.
    String dmg = _currentPrediction.toLowerCase();
    bool isHazardDetected = dmg.contains('pothole');

    Color hudColor = isHazardDetected
        ? Colors.redAccent
        : const Color(0xFFFFD700);
    IconData hudIcon = isHazardDetected
        ? Icons.warning_amber_rounded
        : Icons.radar;

    // Capitalize the first letter for English display
    String displayPrediction = _currentPrediction;
    if (_currentPrediction.isNotEmpty &&
        _currentPrediction != 'Scanning road...') {
      displayPrediction =
          _currentPrediction[0].toUpperCase() +
          _currentPrediction.substring(1).toLowerCase();
    }

    // Determine what to show based on language and detection status
    String finalDisplayText = displayPrediction;
    if (isHazardDetected && isArabic) {
      finalDisplayText = _getArabicLabel(_currentPrediction);
    } else if (!isHazardDetected && isArabic) {
      finalDisplayText = "جاري مسح الطريق...";
    }

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          if (_isCameraInitialized && _cameraController != null)
            Stack(
              children: [
                Positioned.fill(
                  child: ClipRect(
                    child: FittedBox(
                      fit: BoxFit.cover,
                      child: SizedBox(
                        width: _cameraController!.value.previewSize!.height,
                        height: _cameraController!.value.previewSize!.width,
                        child: CameraPreview(_cameraController!),
                      ),
                    ),
                  ),
                ),
                CustomPaint(
                  painter: BoundingBoxPainter(detections: _detections),
                  child: Container(),
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

          Positioned(
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
                    icon: const Icon(
                      Icons.arrow_back_ios,
                      color: Colors.white,
                      size: 28,
                    ),
                    onPressed: () => Navigator.pop(context),
                  ),
                  if (_isDetecting)
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 8,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.08),
                        borderRadius: BorderRadius.circular(30),
                        border: Border.all(
                          color: Colors.white.withValues(alpha: 0.14),
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.2),
                            blurRadius: 12,
                            offset: const Offset(0, 6),
                          ),
                        ],
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
                            isArabic ? "تحليل مباشر" : "LIVE AI",
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                              letterSpacing: 1.2,
                            ),
                          ),
                        ],
                      ),
                    ),
                  _buildModelModeSwitcher(isArabic),
                ],
              ),
            ),
          ),

          if (_isUploadingReport)
            Positioned(
              right: 24,
              top: 150,
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
                        color: Colors.orange,
                        strokeWidth: 2,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      isArabic ? 'جاري الرفع...' : 'Uploading...',
                      style: const TextStyle(color: Colors.white, fontSize: 12),
                    ),
                  ],
                ),
              ),
            ),

          Positioned(
            bottom: 40,
            left: 24,
            right: 24,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(24),
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 15, sigmaY: 15),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 300),
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: isHazardDetected
                          ? [
                              Colors.red.withValues(alpha: 0.34),
                              Colors.black.withValues(alpha: 0.78),
                            ]
                          : [
                              const Color(0xFF1E1E1E).withValues(alpha: 0.78),
                              Colors.black.withValues(alpha: 0.55),
                            ],
                    ),
                    borderRadius: BorderRadius.circular(24),
                    border: Border.all(
                      color: hudColor.withValues(alpha: 0.55),
                      width: 1.8,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: hudColor.withValues(alpha: 0.18),
                        blurRadius: 18,
                        spreadRadius: 1,
                      ),
                    ],
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
                              horizontal: 10,
                              vertical: 6,
                            ),
                            decoration: BoxDecoration(
                              color: hudColor.withValues(alpha: 0.12),
                              borderRadius: BorderRadius.circular(999),
                              border: Border.all(
                                color: hudColor.withValues(alpha: 0.35),
                              ),
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
                        finalDisplayText,
                        style: TextStyle(
                          color: hudColor,
                          fontSize: 22,
                          fontWeight: FontWeight.bold,
                        ),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        isArabic
                            ? 'معالجة عالية السرعة تعمل في الخلفية'
                            : 'High-speed background processing active',
                        style: const TextStyle(
                          color: Colors.white54,
                          fontSize: 14,
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
