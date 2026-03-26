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
      return "Clear Road"; // Default to clear if AI isn't loaded
    }

    try {
      // 1. Load the image from the phone
      File file = File(imagePath);
      final imageData = file.readAsBytesSync();
      img.Image? image = img.decodeImage(imageData);
      if (image == null) return "Clear Road";

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

      // 5. Setup the Output Matrix
      var outputShape = _interpreter!.getOutputTensor(0).shape; 
      
      Object outputBuffer;
      if (outputShape.length == 3) {
        // Matches YOLOv8 [1, 5, 8400]
        outputBuffer = List.generate(outputShape[0], (i) => 
            List.generate(outputShape[1], (j) => 
                List.filled(outputShape[2], 0.0)));
      } else {
        outputBuffer = List.generate(outputShape[0], (i) => List.filled(outputShape[1], 0.0));
      }

      // 6. RUN THE AI MATH!
      _interpreter!.run(inputBuffer, outputBuffer);

      // 7. PARSE THE RESULTS (The Fix!)
      double maxConfidence = 0.0;

      if (outputShape.length == 3) {
        // YOLOv8 outputs 8400 boxes. Index 0-3 are coordinates, Index 4 is the confidence!
        var parsedOutput = outputBuffer as List<List<List<double>>>;
        int numBoxes = outputShape[2];
        
        for (int i = 0; i < numBoxes; i++) {
          double confidence = parsedOutput[0][4][i]; 
          if (confidence > maxConfidence) {
            maxConfidence = confidence;
          }
        }
      } else if (outputShape.length == 2) {
        // Fallback for standard classification models
        var parsedOutput = outputBuffer as List<List<double>>;
        maxConfidence = parsedOutput[0][0];
      }

      print("🧠 AI Max Confidence: ${(maxConfidence * 100).toStringAsFixed(1)}%");
      
      // 8. THE THRESHOLD: Only trigger if the AI is more than 50% sure!
      if (maxConfidence > 0.50) {
        return _labels!.isNotEmpty ? _labels![0] : "Pothole";
      } else {
        return "Clear Road";
      }

    } catch (e) {
      print('❌ Error during prediction: $e');
      return "Clear Road";
    }
  }
}