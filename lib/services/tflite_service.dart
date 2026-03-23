import 'package:tflite_flutter/tflite_flutter.dart';
import 'package:flutter/services.dart';

class TFLiteService {
  Interpreter? _interpreter;
  List<String>? _labels;

  // ==========================================
  // 1. BOOT UP THE AI
  // ==========================================
  Future<void> initializeModel() async {
    try {
      _interpreter = await Interpreter.fromAsset('assets/best_float32.tflite');
      print('✅ AI Model loaded successfully!');

      final labelFile = await rootBundle.loadString('assets/classes.txt');
      
      _labels = labelFile.split('\n').where((label) => label.trim().isNotEmpty).toList();
      print('✅ Labels loaded: $_labels');
      
    } catch (e) {
      print('❌ Error loading AI model: $e');
    }
  }

  // ==========================================
  // 2. SHUT DOWN THE AI (To save battery)
  // ==========================================
  void dispose() {
    _interpreter?.close();
    print('💤 AI Model closed.');
  }

  // ==========================================
  // 3. SCAN AN IMAGE (We will build this next!)
  // ==========================================
  Future<String> analyzeImage(String imagePath) async {
    if (_interpreter == null || _labels == null) {
      return "Model not initialized yet!";
    }
    
    return "Ready to scan!";
  }
}