import 'dart:async';
import 'dart:io';
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

class _LiveCameraScreenState extends State<LiveCameraScreen>
    with WidgetsBindingObserver {
  CameraController? _cameraController;
  final TFLiteService _tfliteService = TFLiteService();

  bool _isCameraInitialized = false;
  bool _isDetecting = false;

  // ⚡ الأهم للأداء: نتائج الكشف بـ ValueNotifier بدل setState.
  //
  // setState كل فريم كان بيعيد بناء الشجرة كاملة — وفيها **BackdropFilter**
  // (blur) مرتين. الـ blur من أغلى العمليات على GPU الموبايل، وإعادة بنائه
  // 8 مرات بالثانية كانت تستهلك أكثر من الاستنتاج نفسه.
  // هلق بس الـ painter ونص الـ HUD بيتحدّثوا، والـ blur بيضل ثابت.
  final ValueNotifier<List<Map<String, dynamic>>> _detections =
      ValueNotifier<List<Map<String, dynamic>>>(const []);
  final ValueNotifier<String> _prediction =
      ValueNotifier<String>('Scanning road...');

  bool _isProcessingFrame = false;
  int _lastFrameTime = 0;
  int _lastDiagnosticLogTime = 0;

  /// الفاصل الزمني بين كل تحليلين. 120ms ≈ 8 تحليلات/ثانية.
  ///
  /// ⚠️ هاد هو **المصدر الوحيد** لتنظيم المعدل — تأكد إن
  /// `TFLiteService.frameSkipRate = 1` وإلا التنظيمين بيتراكمو.
  final int _fpsIntervalMs = 120;

  bool _isUploadingReport = false;
  bool _isReporting = false;
  bool _isRestartingStream = false;
  DateTime? _lastReportTime;

  /// رُفع من 2 إلى 8 ثوانٍ: عند 60 كم/س السيارة بتقطع ~17 متر بالثانية،
  /// فـ 2 ثانية معناها بلاغات متعددة لنفس الحفرة تقريباً.
  final int _cooldownSeconds = 8;

  Position? _cachedPosition;
  bool _isFetchingGps = false;

  /// نتيجة `hasVibrator()` مخزّنة — كانت تُستدعى (await) عند كل كشف.
  bool? _hasVibrator;

  // عتبات ميدانية مؤقتاً: الكشف منخفض العتبة لنعرف إن النموذج يرى الحفرة،
  // والبلاغ أعلى منها مع تأكيد 3 فريمات حتى لا تعود الهلوسة السابقة.
  final double _uiConfidenceThreshold = 0.20;
  final double _reportConfidenceThreshold = 0.35;

  /// رُفع من 1 إلى 3: بـ 1 كان أي false positive بفريم واحد يطلق بلاغ
  /// فعلي + اهتزاز. 3 فريمات متتالية (~0.4 ثانية) بتلغي أغلب الكشوفات
  /// العابرة بدون ما تفوّت حفرة حقيقية.
  final int _requiredConsecutivePotholeFrames = 3;
  int _potholeFrameStreak = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initializeCameraAndAI();
    _warmUpGps();
    _cacheVibratorSupport();
  }

  Future<void> _cacheVibratorSupport() async {
    try {
      _hasVibrator = await Vibration.hasVibrator();
    } catch (_) {
      _hasVibrator = false;
    }
  }

  /// إيقاف الكاميرا والاستنتاج لما التطبيق يروح للخلفية — توفير بطارية
  /// ومنع تسخين الجهاز، وكمان بيمنع كراش عند العودة.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final controller = _cameraController;
    if (controller == null || !controller.value.isInitialized) return;

    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused) {
      _stopAIDetectionStream();
    } else if (state == AppLifecycleState.resumed) {
      if (_isCameraInitialized && !controller.value.isStreamingImages) {
        _startFastAIDetectionStream();
      }
    }
  }

  Future<void> _warmUpGps() async {
    if (_isFetchingGps) return;
    _isFetchingGps = true;
    try {
      final last = await Geolocator.getLastKnownPosition();
      if (last != null && mounted) {
        _cachedPosition = last;
        debugPrint("📍 GPS warm-up (last known)");
      }

      final fresh = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
      ).timeout(const Duration(seconds: 20));

      if (mounted) {
        _cachedPosition = fresh;
        debugPrint("✅ GPS warm-up (fresh)");
      }
    } catch (e) {
      debugPrint("⚠️ GPS warm-up failed: $e — will retry on next report");
    } finally {
      _isFetchingGps = false;
    }
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
      ResolutionPreset.medium,
      enableAudio: false,
      // 🔑 تحديد الصيغة صراحةً: بدونها الصيغة الافتراضية بتختلف بين
      // الأجهزة (أحياناً JPEG/NV21) وبيصير التحويل بالـ service غلط
      // أو بيفشل صامتاً.
      imageFormatGroup:
          Platform.isAndroid ? ImageFormatGroup.yuv420 : ImageFormatGroup.bgra8888,
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
    final controller = _cameraController;
    if (controller == null || !controller.value.isInitialized) return;

    // 🔑 حماية من تشغيل الستريم مرتين (كان ممكن يصير عند العودة من
    // رفع بلاغ + استئناف من الـ lifecycle بنفس الوقت) — التشغيل
    // المزدوج بيرمي استثناء وبيضاعف الحمل.
    if (controller.value.isStreamingImages) return;

    _isDetecting = true;
    _prediction.value = 'Scanning road...';
    if (mounted) setState(() {});

    controller.startImageStream((CameraImage image) async {
      if (_isProcessingFrame || !mounted) return;

      final currentTime = DateTime.now().millisecondsSinceEpoch;
      if (currentTime - _lastFrameTime < _fpsIntervalMs) return;

      _isProcessingFrame = true;
      _lastFrameTime = currentTime;

      try {
        final result = await _tfliteService.predictFrameWithBoxes(image);

        // 🔑 null = الفريم انتخطّى أو الـ worker كان مشغول.
        // لازم نتجاهله بالكامل، مش نعامله كـ "طريق نظيف"، وإلا
        // المربعات بترفرف والعدّاد الزمني بيتصفّر كل فريم.
        if (result == null) return;

        // سجل ميداني محدود: يكشف فوراً إن المشكلة عتبة ثقة أم خطأ worker
        // من دون إغراق logcat بسجل لكل فريم.
        final now = DateTime.now().millisecondsSinceEpoch;
        if (now - _lastDiagnosticLogTime >= 2000) {
          _lastDiagnosticLogTime = now;
          final maxScore = (result['maxScore'] as num?)?.toDouble() ?? 0.0;
          final count = (result['detections'] as List?)?.length ?? 0;
          debugPrint(
            '🔎 AI diagnostics | maxScore=${maxScore.toStringAsFixed(3)} '
            '| detections=$count | frame=${image.width}x${image.height}',
          );
        }

        final detections = _normalizeDetections(result['detections']);
        final uiPothole = _pickBestPotholeDetection(
          detections,
          minConfidence: _uiConfidenceThreshold,
        );
        final reportPothole = _pickBestPotholeDetection(
          detections,
          minConfidence: _reportConfidenceThreshold,
        );

        final String detectedDamage = uiPothole == null
            ? 'Clear Road'
            : (uiPothole['label'] as String? ?? 'Pothole');

        // تحديث بدون setState — الـ blur والـ HUD ما بيتعاد بناؤهم
        _prediction.value = detectedDamage;
        _detections.value =
            uiPothole == null ? const [] : <Map<String, dynamic>>[uiPothole];

        if (reportPothole != null) {
          _potholeFrameStreak++;
        } else {
          _potholeFrameStreak = 0;
        }

        final bool isTemporalConfirmed =
            _potholeFrameStreak >= _requiredConsecutivePotholeFrames;

        if (isTemporalConfirmed && !_isUploadingReport && !_isReporting) {
          final bool canReport = _lastReportTime == null ||
              DateTime.now().difference(_lastReportTime!).inSeconds >
                  _cooldownSeconds;

          if (canReport) {
            if (_hasVibrator == true) {
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
    if (mounted) setState(() => _isUploadingReport = true);
    final isArabic = ApiService.currentLanguage == 'ar';
    bool streamWasPaused = false;

    try {
      Position position;
      if (_cachedPosition != null) {
        position = _cachedPosition!;
        _warmUpGps(); // جدّد بالخلفية للبلاغ القادم
      } else {
        try {
          position = await Geolocator.getCurrentPosition(
            desiredAccuracy: LocationAccuracy.medium,
          ).timeout(
            const Duration(seconds: 15),
            onTimeout: () => throw TimeoutException('GPS timeout'),
          );
          _cachedPosition = position;
        } catch (e) {
          final gpsError = e.toString().contains('timeout')
              ? (isArabic
                  ? 'انتهت مهلة GPS. تأكد من تفعيله وكونك في الهواء الطلق.'
                  : 'GPS timed out. Make sure it\'s enabled and you\'re outdoors.')
              : (isArabic
                  ? 'تعذّر الحصول على الموقع: $e'
                  : 'Could not get location: $e');

          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(
              content: Text('❌ $gpsError'),
              backgroundColor: Colors.red,
              behavior: SnackBarBehavior.floating,
              duration: const Duration(seconds: 4),
            ));
          }
          throw Exception(gpsError);
        }
      }

      final controller = _cameraController;
      if (controller == null || !controller.value.isInitialized) {
        throw Exception('Camera Error: Camera controller not initialized');
      }

      if (controller.value.isStreamingImages) {
        await controller.stopImageStream();
        streamWasPaused = true;
        await Future.delayed(const Duration(milliseconds: 200));
      }

      XFile capturedPhoto;
      try {
        capturedPhoto = await controller.takePicture().timeout(
              const Duration(seconds: 5),
              onTimeout: () => throw TimeoutException('Photo capture timeout'),
            );
      } catch (e) {
        final photoError = e.toString().contains('timeout')
            ? 'Photo Capture Error: Camera took >5s to capture photo'
            : 'Photo Capture Error: $e';
        debugPrint("❌ $photoError");
        throw Exception(photoError);
      }

      const int typeId = 1; // pothole فقط

      final bool success = await ApiService.submitReport(
        photo: capturedPhoto,
        latitude: position.latitude,
        longitude: position.longitude,
        typeId: typeId,
      ).timeout(
        const Duration(seconds: 30),
        onTimeout: () => throw TimeoutException('API request timeout (>30s)'),
      );

      if (mounted) {
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
      final errorMsg = e.toString();
      debugPrint("❌ Auto-Report Error: $errorMsg");

      String displayError = errorMsg;
      if (errorMsg.contains('Connection refused')) {
        displayError = 'Network Error: Cannot connect to server';
      } else if (errorMsg.contains('timeout')) {
        displayError = 'Timeout Error: Request took too long';
      } else if (errorMsg.contains('Socket')) {
        displayError = 'Network Error: Internet connection lost';
      } else if (errorMsg.contains('Camera')) {
        displayError = 'Camera Error: Unable to capture photo';
      } else if (errorMsg.contains('GPS')) {
        displayError = 'Location Error: GPS not available';
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(
              isArabic ? '❌ خطأ: $errorMsg' : '❌ Error: $displayError'),
          backgroundColor: Colors.red,
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 3),
        ));
      }
    } finally {
      _isReporting = false;
      if (mounted &&
          streamWasPaused &&
          _isCameraInitialized &&
          !_isRestartingStream) {
        _isRestartingStream = true;
        await Future.delayed(const Duration(milliseconds: 100));
        _startFastAIDetectionStream();
        _isRestartingStream = false;
      }
      if (mounted) setState(() => _isUploadingReport = false);
    }
  }

  List<Map<String, dynamic>> _normalizeDetections(dynamic rawDetections) {
    if (rawDetections is! List || rawDetections.isEmpty) return const [];

    final normalized = <Map<String, dynamic>>[];
    for (final item in rawDetections) {
      if (item is! Map) continue;
      normalized.add({
        'x1': (item['x1'] as num?)?.toDouble() ?? 0.0,
        'y1': (item['y1'] as num?)?.toDouble() ?? 0.0,
        'x2': (item['x2'] as num?)?.toDouble() ?? 0.0,
        'y2': (item['y2'] as num?)?.toDouble() ?? 0.0,
        'conf': (item['conf'] as num?)?.toDouble() ?? 0.0,
        'label': (item['label'] ?? '').toString(),
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
      if (conf < bestConf) continue;

      best = d;
      bestConf = conf;
    }

    return best;
  }

  void _stopAIDetectionStream() {
    try {
      final controller = _cameraController;
      if (controller != null && controller.value.isStreamingImages) {
        controller.stopImageStream();
      }
    } catch (_) {
      // الستريم ما كان شغال — تجاهل بأمان
    }
    if (mounted) setState(() => _isDetecting = false);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _stopAIDetectionStream();
    _cameraController?.dispose();
    _tfliteService.dispose();
    _detections.dispose();
    _prediction.dispose();
    super.dispose();
  }

  String _getArabicLabel(String englishLabel) {
    if (englishLabel.toLowerCase().contains('pothole')) return 'حفرة';
    return englishLabel;
  }

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
                // يُعاد رسمه فقط عند تغيّر المربعات — مش مع كل rebuild
                Positioned.fill(
                  child: ValueListenableBuilder<List<Map<String, dynamic>>>(
                    valueListenable: _detections,
                    builder: (_, detections, __) => CustomPaint(
                      size: Size.infinite,
                      painter: BoundingBoxPainter(detections: detections),
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
                          color: Colors.orange, strokeWidth: 2),
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
    );
  }

  /// الـ HUD: الـ BackdropFilter (blur) مبني مرة وحدة برا الـ builder،
  /// وبس المحتوى الداخلي بيتحدّث مع تغيّر النتيجة.
  Widget _buildHud(bool isArabic) {
    return Positioned(
      bottom: 40,
      left: 24,
      right: 24,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(24),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 15, sigmaY: 15),
          child: ValueListenableBuilder<String>(
            valueListenable: _prediction,
            builder: (_, prediction, __) {
              final dmg = prediction.toLowerCase();
              final isHazardDetected = dmg.contains('pothole');
              final hudColor =
                  isHazardDetected ? Colors.redAccent : const Color(0xFFFFD700);
              final hudIcon = isHazardDetected
                  ? Icons.warning_amber_rounded
                  : Icons.radar;

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
                          ? 'معالجة عالية السرعة تعمل في الخلفية'
                          : 'Zero-lag background processing active',
                      style:
                          const TextStyle(color: Colors.white54, fontSize: 14),
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}
