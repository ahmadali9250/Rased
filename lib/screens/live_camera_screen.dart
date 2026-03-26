import 'dart:ui';
import 'dart:io';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import '../services/api_service.dart';
import '../services/tflite_service.dart';

/// The Live AI Dashcam Screen.
///
/// Uses a "Smart Throttle" to silently capture a frame every 2 seconds and feed 
/// it to the local TensorFlow Lite YOLO model, preventing battery drain and overheating.
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
  Timer? _aiTimer; // The Smart Throttle Timer

  @override
  void initState() {
    super.initState();
    _initializeCameraAndAI();
  }

  /// Boots up the TensorFlow model and the hardware camera simultaneously.
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

    // Medium resolution keeps the AI fast and memory usage low!
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

  /// The "Smart Dashcam Throttle". 
  /// Silently snaps a photo every 2 seconds and feeds it to your YOLO model.
  void _startAIDetectionStream() {
    if (_cameraController == null || !_cameraController!.value.isInitialized) return;

    setState(() {
      _isDetecting = true;
      _currentPrediction = "Scanning road...";
    });

    // Run the AI every 2 seconds
    _aiTimer = Timer.periodic(const Duration(seconds: 2), (timer) async {
      if (_isProcessingFrame || !mounted) return;
      
      _isProcessingFrame = true;

      try {
        // 1. Take a silent picture
        XFile imageFile = await _cameraController!.takePicture();
        
        // 2. Feed it to your existing TFLite Service!
        String detectedDamage = await _tfliteService.predictImage(imageFile.path);

        if (mounted) {
          setState(() {
            _currentPrediction = detectedDamage;
            // Optional: If it detects something bad, you can trigger a beep or auto-report!
          });
        }

        // 3. CRITICAL: Delete the image immediately so we don't fill up the phone's storage!
        File(imageFile.path).delete().catchError((e) => debugPrint("Could not delete temp file: $e"));

      } catch (e) {
        debugPrint("❌ AI Stream Error: $e");
      } finally {
        _isProcessingFrame = false; 
      }
    });
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
    _tfliteService.dispose(); // Shut down the AI brain
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isArabic = ApiService.currentLanguage == 'ar';

    // --- FIX: Case-insensitive check ---
    // We check if the AI returned 'pothole', 'Pothole', 'POTHOLE', etc.
    bool isHazardDetected = _currentPrediction.toLowerCase().contains('pothole');

    // Determine the color of the HUD based on the AI output
    Color hudColor = isHazardDetected ? Colors.redAccent : const Color(0xFFFFD700);
    IconData hudIcon = isHazardDetected ? Icons.warning_amber_rounded : Icons.radar;

    // Capitalize the first letter for UI display (e.g. "pothole" -> "Pothole")
    String displayPrediction = _currentPrediction;
    if (_currentPrediction.isNotEmpty && _currentPrediction != 'Scanning road...') {
        displayPrediction = _currentPrediction[0].toUpperCase() + _currentPrediction.substring(1).toLowerCase();
    }

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          // --- 1. THE CAMERA PREVIEW ---
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

          // --- 2. TOP GRADIENT & BACK BUTTON ---
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

          // --- 3. BOTTOM AI HUD ---
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
                        ? Colors.red.withValues(alpha: 0.3) // Flash red if a pothole is found!
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