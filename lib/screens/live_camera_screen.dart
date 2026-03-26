import 'dart:ui';
import 'dart:io';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:geolocator/geolocator.dart';
import '../services/api_service.dart';
import '../services/tflite_service.dart';

/// The Live AI Dashcam Screen.
///
/// Features Auto-Reporting: When a hazard is detected, it grabs the GPS location,
/// uploads the image to the C# backend, and initiates a 10-second cooldown to 
/// prevent database spamming (The "Red Light" fix).
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
  bool _isProcessingFrame = false; 

  String _currentPrediction = 'Scanning road...';
  Timer? _aiTimer; 

  // --- AUTO-REPORTING STATE ---
  bool _isUploadingReport = false;
  DateTime? _lastReportTime;
  final int _cooldownSeconds = 10; // Wait 10 seconds between uploads!

  @override
  void initState() {
    super.initState();
    _initializeCameraAndAI();
  }

  Future<void> _initializeCameraAndAI() async {
    await _tfliteService.initializeModel();

    final cameras = await availableCameras();
    if (cameras.isEmpty) {
      debugPrint("❌ No cameras found on this device.");
      return;
    }

    final backCamera = cameras.firstWhere(
      (cam) => cam.lensDirection == CameraLensDirection.back,
      orElse: () => cameras.first,
    );

    _cameraController = CameraController(
      backCamera,
      ResolutionPreset.medium, 
      enableAudio: false, 
    );

    try {
      await _cameraController!.initialize();
      if (!mounted) return;

      setState(() {
        _isCameraInitialized = true;
      });

      _startAIDetectionStream();

    } catch (e) {
      debugPrint("❌ Camera initialization error: $e");
    }
  }

  void _startAIDetectionStream() {
    if (_cameraController == null || !_cameraController!.value.isInitialized) return;

    setState(() {
      _isDetecting = true;
      _currentPrediction = "Scanning road...";
    });

    _aiTimer = Timer.periodic(const Duration(seconds: 2), (timer) async {
      if (_isProcessingFrame || !mounted) return;
      
      _isProcessingFrame = true;

      try {
        // 1. Take a silent picture
        XFile imageFile = await _cameraController!.takePicture();
        
        // 2. Feed it to the AI
        String detectedDamage = await _tfliteService.predictImage(imageFile.path);
        bool isHazardDetected = detectedDamage.toLowerCase().contains('pothole');

        if (mounted) {
          setState(() {
            _currentPrediction = detectedDamage;
          });
        }

        // 3. THE AUTO-REPORTING ENGINE
        if (isHazardDetected && !_isUploadingReport) {
          
          bool canReport = _lastReportTime == null || 
              DateTime.now().difference(_lastReportTime!).inSeconds > _cooldownSeconds;

          if (canReport) {
            // FIRE AND FORGET! We call this without 'await' so the camera keeps running smoothly
            _autoSubmitReport(imageFile.path, detectedDamage);
          } else {
            // Cooldown is active. Just delete the frame.
            File(imageFile.path).delete().catchError((_) {});
          }
        } else {
          // Clear road. Delete the frame.
          File(imageFile.path).delete().catchError((_) {});
        }

      } catch (e) {
        debugPrint("❌ AI Stream Error: $e");
      } finally {
        _isProcessingFrame = false; 
      }
    });
  }

  /// Automatically grabs GPS coordinates and uploads the hazard to the backend.
  Future<void> _autoSubmitReport(String imagePath, String damageType) async {
    setState(() => _isUploadingReport = true);
    final isArabic = ApiService.currentLanguage == 'ar';

    // Show a quick notification so the driver knows it worked!
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(isArabic ? '🚨 تم رصد ضرر! جاري الإرسال تلقائياً...' : '🚨 Hazard detected! Auto-reporting...'),
        backgroundColor: Colors.orange,
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 2),
      ),
    );

    try {
      // 1. Get exact coordinates instantly
      Position position = await Geolocator.getCurrentPosition(desiredAccuracy: LocationAccuracy.high);

      // 2. Convert string to ID
      int typeId = 1; // Default to Pothole
      if (damageType.toLowerCase().contains('crack')) typeId = 2;
      if (damageType.toLowerCase().contains('faded')) typeId = 3;
      if (damageType.toLowerCase().contains('manhole')) typeId = 4;

      // 3. Upload to backend
      bool success = await ApiService.submitReport(
        photo: XFile(imagePath),
        latitude: position.latitude,
        longitude: position.longitude,
        typeId: typeId,
      );

      if (success) {
        debugPrint("✅ Auto-Report submitted successfully!");
        _lastReportTime = DateTime.now(); // Reset the cooldown timer!
      } else {
        debugPrint("❌ Auto-Report failed to upload.");
      }

    } catch (e) {
      debugPrint("❌ Auto-Report Error: $e");
    } finally {
      // Delete the image from the phone and unlock the uploader
      File(imagePath).delete().catchError((_) {});
      if (mounted) {
        setState(() => _isUploadingReport = false);
      }
    }
  }

  void _stopAIDetectionStream() {
    _aiTimer?.cancel();
    if (mounted) {
      setState(() {
        _isDetecting = false;
        _currentPrediction = 'AI Paused';
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
            CameraPreview(_cameraController!)
          else
            const Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  CircularProgressIndicator(color: Color(0xFFFFD700)),
                  SizedBox(height: 16),
                  Text("Initializing AI Dashcam...", style: TextStyle(color: Colors.white54)),
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
                        Text(isArabic ? "تحليل مباشر" : "LIVE AI", style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, letterSpacing: 1.5)),
                      ],
                    ),
                  const SizedBox(width: 48), 
                ],
              ),
            ),
          ),

          // Uploading Indicator (Shows subtly in the middle right)
          if (_isUploadingReport)
            Positioned(
              right: 24, top: 150,
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.black54,
                  borderRadius: BorderRadius.circular(30),
                ),
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
                        isArabic ? 'يبحث الذكاء الاصطناعي عن الأضرار في الطريق' : 'AI is monitoring the road for hazards',
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