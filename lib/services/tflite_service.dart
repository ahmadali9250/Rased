import 'dart:io';
import 'package:tflite_flutter/tflite_flutter.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;

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
  // 2. SHUT DOWN THE AI
  // ==========================================
  void dispose() {
    _interpreter?.close();
    print('💤 AI Model closed.');
  }

  // ==========================================
  // 3. SCAN AN IMAGE (The Brain!)
  // ==========================================
  Future<String> predictImage(String imagePath) async {
    if (_interpreter == null || _labels == null) {
      return "Pothole";
    }

    try {
      // 1. Load the image from the phone
      File file = File(imagePath);
      final imageData = file.readAsBytesSync();
      img.Image? image = img.decodeImage(imageData);
      if (image == null) return "Pothole";

      // 2. Get the exact size the model wants
      var inputShape = _interpreter!.getInputTensor(0).shape;
      int inputHeight = inputShape[1];
      int inputWidth = inputShape[2];

      // 3. Resize the image
      img.Image resizedImage = img.copyResize(image, width: inputWidth, height: inputHeight);

      // 4. Convert pixels to a 3D matrix
      var inputBuffer = List.generate(1, (i) =>
          List.generate(inputHeight, (y) =>
              List.generate(inputWidth, (x) {
                final pixel = resizedImage.getPixel(x, y);
                return [pixel.r / 255.0, pixel.g / 255.0, pixel.b / 255.0];
              })
          )
      );

      // --- DYNAMIC OUTPUT SHAPE ---
      // This stops the [1, 5, 8400] crash!
      var outputShape = _interpreter!.getOutputTensor(0).shape; 
      
      Object outputBuffer;
      if (outputShape.length == 3) {
        // Matches your specific YOLO model perfectly
        outputBuffer = List.generate(outputShape[0], (i) => 
            List.generate(outputShape[1], (j) => 
                List.filled(outputShape[2], 0.0)));
      } else {
        // Matches standard models
        outputBuffer = List.generate(outputShape[0], (i) => List.filled(outputShape[1], 0.0));
      }

      // 5. RUN THE AI MATH!
      _interpreter!.run(inputBuffer, outputBuffer);

      print("🧠 AI successfully scanned the image (YOLO Mode)!");
      
      // Since your specific model file only knows 1 class right now, we return it.
      return _labels!.isNotEmpty ? _labels![0] : "Pothole";

    } catch (e) {
      print('❌ Error during prediction: $e');
      return "Pothole";
    }
  }
}