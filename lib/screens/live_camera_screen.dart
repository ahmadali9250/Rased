import 'dart:async';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:geolocator/geolocator.dart';
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
  CameraController? _cameraController;
  final TFLiteService _tfliteService = TFLiteService();
  
  bool _isCameraInitialized = false;
  bool _isDetecting = false;

  List<Map<String, dynamic>> _detections = [];

  bool _isProcessingFrame = false; 
  int _lastFrameTime = 0;
  final int _fpsIntervalMs = 120; 

  String _currentPrediction = 'Scanning road...';

  bool _isUploadingReport = false;
  bool _isReporting = false;
  DateTime? _lastReportTime;
  final int _cooldownSeconds = 2;

  final double _uiConfidenceThreshold = 0.30;
  final double _reportConfidenceThreshold = 0.50;
  final int _requiredConsecutivePotholeFrames = 1;
  int _potholeFrameStreak = 0;

  @override
  void initState() {
    super.initState();
    _initializeCameraAndAI();
  }

  Future<void> _initializeCameraAndAI() async {
    await _tfliteService.initializeModel();

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
    );

    try {
      await _cameraController!.initialize();
      if (!mounted) return;

      setState(() => _isCameraInitialized = true);
      _startFastAIDetectionStream();
    } catch (e) {
      debugPrint("❌ Camera initialization error: $e");
    }
  }

  void _startFastAIDetectionStream() {
    if (_cameraController == null || !_cameraController!.value.isInitialized) return;

    setState(() {
      _isDetecting = true;
      _currentPrediction = "Scanning road...";
    });

    _cameraController!.startImageStream((CameraImage image) async {
      if (_isProcessingFrame || !mounted) return;

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
        );
        String detectedDamage = uiPothole == null
            ? 'Clear Road'
            : (uiPothole['label'] as String? ?? 'Pothole');

        if (mounted) {
          setState(() {
            _currentPrediction = detectedDamage;
            _detections = uiPothole == null ? [] : [uiPothole];
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
          bool canReport = _lastReportTime == null || 
              DateTime.now().difference(_lastReportTime!).inSeconds > _cooldownSeconds;

          if (canReport) {
            if (await Vibration.hasVibrator()) {
              Vibration.vibrate(duration: 400);
            }

            _lastReportTime = DateTime.now();
            _isReporting = true;
            _potholeFrameStreak = 0;
            await _autoSubmitReport(detectedDamage);
          }
        }
      } catch (e) {
        debugPrint("❌ AI Stream Error: $e");
      } finally {
        _isProcessingFrame = false;
      }
    });
  }

  Future<void> _autoSubmitReport(String damageType) async {
    setState(() => _isUploadingReport = true);
    final isArabic = ApiService.currentLanguage == 'ar';
    bool streamWasPaused = false;

    try {
      // Get GPS location with timeout (fail gracefully if unavailable)
      Position position;
      try {
        position = await Geolocator.getCurrentPosition(
          desiredAccuracy: LocationAccuracy.high
        ).timeout(
          const Duration(seconds: 10),
          onTimeout: () => throw TimeoutException('GPS timeout'),
        );

        if (position.latitude == 0.0 && position.longitude == 0.0) {
          throw Exception('Invalid GPS location: coordinates are (0,0)');
        }

        debugPrint("✅ GPS acquired: ${position.latitude}, ${position.longitude}");
      } catch (e) {
        String gpsError = 'GPS Error: ';
        if (e.toString().contains('Location services are disabled')) {
          gpsError += 'Location services disabled on device';
        } else if (e.toString().contains('Permission')) {
          gpsError += 'Location permission denied by user';
        } else if (e.toString().contains('timeout')) {
          gpsError += 'GPS took too long (>10s) - weak signal or indoors';
        } else {
          gpsError += e.toString();
        }
        debugPrint("⚠️ $gpsError. Using default location (0,0)");
        
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(isArabic 
              ? '❌ لا يمكن إرسال البلاغ بدون موقع GPS صالح'
              : '❌ Cannot send report without valid GPS location ($gpsError)'),
            backgroundColor: Colors.red,
            behavior: SnackBarBehavior.floating,
            duration: const Duration(seconds: 3),
          ));
        }

        throw Exception(gpsError);
      }

      if (_cameraController == null || !_cameraController!.value.isInitialized) {
        throw Exception('Camera Error: Camera controller not initialized');
      }

      // Pause stream and capture a photo.
      if (_cameraController!.value.isStreamingImages) {
        await _cameraController!.stopImageStream();
        streamWasPaused = true;
        await Future.delayed(const Duration(milliseconds: 200));
        debugPrint("✅ Camera stream paused");
      }

      XFile? capturedPhoto;
      try {
        debugPrint("📸 Attempting to capture photo...");
        capturedPhoto = await _cameraController!.takePicture().timeout(
          const Duration(seconds: 5),
          onTimeout: () => throw TimeoutException('Photo capture timeout'),
        );
        debugPrint("✅ Photo captured: ${capturedPhoto!.path}");
      } catch (e) {
        String photoError = 'Photo Capture Error: ';
        if (e.toString().contains('timeout')) {
          photoError += 'Camera took >5s to capture photo';
        } else if (e.toString().contains('camera')) {
          photoError += 'Camera hardware error or not ready';
        } else {
          photoError += e.toString();
        }
        debugPrint("❌ $photoError");
        throw Exception(photoError);
      }

      // Force report type to pothole only.
      int typeId = 1;

      debugPrint("🚀 Submitting report to API ($damageType, typeId=$typeId, lat=${position.latitude}, lon=${position.longitude})...");
      bool success = await ApiService.submitReport(
        photo: capturedPhoto,
        latitude: position.latitude,
        longitude: position.longitude,
        typeId: typeId,
      ).timeout(
        const Duration(seconds: 30),
        onTimeout: () => throw TimeoutException('API request timeout (>30s)'),
      );

      if (mounted) {
        // success includes normal create (200/201) and duplicate hazard accepted as success (409)
        debugPrint(success ? "✅ Report accepted successfully" : "⚠️ Report submission returned false");
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(success
            ? (isArabic ? '✅ تم إرسال البلاغ!' : '✅ Report sent!')
            : (isArabic ? '❌ فشل الإرسال' : '❌ Failed to send')),
          backgroundColor: success ? Colors.green : Colors.red,
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 2),
        ));
      }
    } catch (e) {
      String errorMsg = e.toString();
      debugPrint("❌ Auto-Report Error: $errorMsg");
      
      // Provide more specific error details
      String displayError = errorMsg;
      if (errorMsg.contains('Connection refused')) {
        displayError = 'Network Error: Cannot connect to server - check internet connection';
      } else if (errorMsg.contains('timeout')) {
        displayError = 'Timeout Error: Request took too long - network may be slow';
      } else if (errorMsg.contains('Socket')) {
        displayError = 'Network Error: Internet connection lost';
      } else if (errorMsg.contains('Camera')) {
        displayError = 'Camera Error: Unable to capture photo';
      } else if (errorMsg.contains('GPS')) {
        displayError = 'Location Error: GPS not available';
      }
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(isArabic 
            ? '❌ خطأ: $errorMsg'
            : '❌ Error: $displayError'),
          backgroundColor: Colors.red,
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 3),
        ));
      }
    } finally {
      _isReporting = false;
      if (mounted && streamWasPaused && _cameraController != null && _isCameraInitialized) {
        await Future.delayed(const Duration(milliseconds: 100));
        debugPrint("🎥 Resuming camera stream...");
        _startFastAIDetectionStream();
      }
      if (mounted) setState(() => _isUploadingReport = false);
    }
  }

  List<Map<String, dynamic>> _normalizeDetections(dynamic rawDetections) {
    if (rawDetections is! List) return [];

    final normalized = <Map<String, dynamic>>[];
    for (final item in rawDetections) {
      if (item is! Map) continue;

      final map = Map<String, dynamic>.from(item as Map);
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

  Map<String, dynamic>? _pickBestPotholeDetection(
    List<Map<String, dynamic>> detections, {
    required double minConfidence,
  }) {
    Map<String, dynamic>? best;
    double bestConf = minConfidence;

    for (final d in detections) {
      final label = (d['label'] ?? '').toString().toLowerCase();
      final conf = (d['conf'] as num?)?.toDouble() ?? 0.0;
      if (!label.contains('pothole')) continue;
      if (conf < minConfidence) continue;

      if (best == null || conf > bestConf) {
        best = d;
        bestConf = conf;
      }
    }

    return best;
  }

  void _stopAIDetectionStream() {
    try {
      _cameraController?.stopImageStream();
    } catch (_) {
      // Stream was not active — safe to ignore
    }
    if (mounted) {
      setState(() {
        _isDetecting = false;
      });
    }
  }

  @override
  void dispose() {
    _stopAIDetectionStream();
    _cameraController?.dispose();
    _tfliteService.dispose(); 
    super.dispose();
  }

  // Helper method to properly translate AI labels to Arabic for the UI
  String _getArabicLabel(String englishLabel) {
    String lower = englishLabel.toLowerCase();
    if (lower.contains('pothole')) return 'حفرة';
    return englishLabel;
  }

  @override
  Widget build(BuildContext context) {
    final isArabic = ApiService.currentLanguage == 'ar';
    
    // UI highlights only pothole as hazard.
    String dmg = _currentPrediction.toLowerCase();
    bool isHazardDetected = dmg.contains('pothole');
                            
    Color hudColor = isHazardDetected ? Colors.redAccent : const Color(0xFFFFD700);
    IconData hudIcon = isHazardDetected ? Icons.warning_amber_rounded : Icons.radar;

    // Capitalize the first letter for English display
    String displayPrediction = _currentPrediction;
    if (_currentPrediction.isNotEmpty && _currentPrediction != 'Scanning road...') {
        displayPrediction = _currentPrediction[0].toUpperCase() + _currentPrediction.substring(1).toLowerCase();
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
            top: 0, left: 0, right: 0,
            child: Container(
              height: 120,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter, end: Alignment.bottomCenter,
                  colors: [Colors.black.withValues(alpha: 0.88), Colors.transparent],
                ),
              ),
              padding: const EdgeInsets.only(top: 50, left: 16, right: 16),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  IconButton(
                    icon: const Icon(Icons.arrow_back_ios, color: Colors.white, size: 28),
                    onPressed: () => Navigator.pop(context),
                  ),
                  if (_isDetecting)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.08),
                        borderRadius: BorderRadius.circular(30),
                        border: Border.all(color: Colors.white.withValues(alpha: 0.14)),
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
                  const SizedBox(width: 48), 
                ],
              ),
            ),
          ),

          if (_isUploadingReport)
            Positioned(
              right: 24, top: 150,
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(30)),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(color: Colors.orange, strokeWidth: 2)),
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
            bottom: 40, left: 24, right: 24,
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
                    border: Border.all(color: hudColor.withValues(alpha: 0.55), width: 1.8),
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
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                            decoration: BoxDecoration(
                              color: hudColor.withValues(alpha: 0.12),
                              borderRadius: BorderRadius.circular(999),
                              border: Border.all(color: hudColor.withValues(alpha: 0.35)),
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
                        style: TextStyle(color: hudColor, fontSize: 22, fontWeight: FontWeight.bold),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        isArabic ? 'معالجة عالية السرعة تعمل في الخلفية' : 'Zero-lag background processing active',
                        style: const TextStyle(color: Colors.white54, fontSize: 14),
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