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
  final int _fpsIntervalMs = 250; 

  String _currentPrediction = 'Scanning road...';

  bool _isUploadingReport = false;
  DateTime? _lastReportTime;
  final int _cooldownSeconds = 10; 

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

    // 🚨 FIX 1: Lower resolution. The AI shrinks the image anyway!
    // This cuts the pixel-processing time by over 70%.
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
        String detectedDamage = result['label'];
        if (mounted) {
          setState(() {
          _currentPrediction = detectedDamage;
          _detections = result['detections']; // for boxes feedback
          });
        }
        bool isHazardDetected = detectedDamage.toLowerCase().contains('pothole');

        if (mounted) {
          setState(() {
            _currentPrediction = detectedDamage;
          });
        }

        if (isHazardDetected && !_isUploadingReport) {

          if ((await Vibration.hasVibrator()) ?? false) {
            Vibration.vibrate(duration: 400);
          }
          bool canReport = _lastReportTime == null || 
              DateTime.now().difference(_lastReportTime!).inSeconds > _cooldownSeconds;

          if (canReport) {
            _autoSubmitReport(null, detectedDamage);
          } 
        }
      } catch (e) {
        debugPrint("❌ AI Stream Error: $e");
      } finally {
        _isProcessingFrame = false; 
      }
    });
  }

Future<void> _autoSubmitReport(String? imagePath, String damageType) async {
  setState(() => _isUploadingReport = true);
  final isArabic = ApiService.currentLanguage == 'ar';

  try {
    Position position = await Geolocator.getCurrentPosition(
      desiredAccuracy: LocationAccuracy.high
    );
    _lastReportTime = DateTime.now();

    // ✅ إضافة — الإرسال الفعلي للباك إند
    final dmg = damageType.toLowerCase();
    int typeId = dmg.contains('crack') ? 2 :
                 dmg.contains('manhole') ? 4 :
                 dmg.contains('pothole') ? 1 : 1;

    bool success = await ApiService.submitLocationOnly(
      latitude: position.latitude,
      longitude: position.longitude,
      typeId: typeId,
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
    debugPrint("❌ Auto-Report Error: $e");
  } finally {
    if (mounted) setState(() => _isUploadingReport = false);
  }
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

  @override
  Widget build(BuildContext context) {
    final isArabic = ApiService.currentLanguage == 'ar';
    bool isHazardDetected = _currentPrediction.toLowerCase().contains('pothole');
    Color hudColor = isHazardDetected ? Colors.redAccent : const Color(0xFFFFD700);
    IconData hudIcon = isHazardDetected ? Icons.warning_amber_rounded : Icons.radar;

    String displayPrediction = _currentPrediction;
    if (_currentPrediction.isNotEmpty && _currentPrediction != 'Scanning road...') {
        displayPrediction = _currentPrediction[0].toUpperCase() + _currentPrediction.substring(1).toLowerCase();
    }

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          if (_isCameraInitialized && _cameraController != null)
            Stack(
              children: [
                CameraPreview(_cameraController!),
                CustomPaint(
                  painter: BoundingBoxPainter(detections: _detections),
                  child: Container(),
                ),
              ],
            )
          else
            const Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  CircularProgressIndicator(color: Color(0xFFFFD700)),
                  SizedBox(height: 16),
                  Text("Initializing High-Speed Dashcam...", style: TextStyle(color: Colors.white54)),
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
                  colors: [Colors.black.withValues(alpha: 0.8), Colors.transparent],
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
                    Row(
                      children: [
                        Container(width: 12, height: 12, decoration: const BoxDecoration(color: Colors.redAccent, shape: BoxShape.circle)),
                        const SizedBox(width: 8),
                        Text(isArabic ? "تحليل مباشر (4 FPS)" : "LIVE AI (4 FPS)", style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, letterSpacing: 1.5)),
                      ],
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
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(width: 16, height: 16, child: CircularProgressIndicator(color: Colors.orange, strokeWidth: 2)),
                    SizedBox(width: 8),
                    Text("Uploading...", style: TextStyle(color: Colors.white, fontSize: 12)),
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
                  padding: const EdgeInsets.all(24),
                  decoration: BoxDecoration(
                    color: isHazardDetected 
                        ? Colors.red.withValues(alpha: 0.3) 
                        : const Color(0xFF1E1E1E).withValues(alpha: 0.7),
                    borderRadius: BorderRadius.circular(24),
                    border: Border.all(color: hudColor.withValues(alpha: 0.5), width: 2),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(hudIcon, color: hudColor, size: 40),
                      const SizedBox(height: 12),
                      Text(
                        isHazardDetected && isArabic ? 'حفرة' : displayPrediction,
                        style: TextStyle(color: hudColor, fontSize: 24, fontWeight: FontWeight.bold),
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