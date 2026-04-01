import 'dart:io';
import 'dart:typed_data';
import 'package:camera/camera.dart';
import 'package:tflite_flutter/tflite_flutter.dart';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart'; 
import 'package:image/image.dart' as img;

class TFLiteService {
  Interpreter? _interpreter;
  List<String>? _labels;
  
  int _inputWidth = 0;
  int _inputHeight = 0;

  Future<void> initializeModel() async {
    try {
      _interpreter = await Interpreter.fromAsset('assets/best_float32.tflite');
      debugPrint('✅ AI Model loaded successfully!');

      final labelFile = await rootBundle.loadString('assets/classes.txt');
      _labels = labelFile.split('\n').where((label) => label.trim().isNotEmpty).toList();
      
      var inputShape = _interpreter!.getInputTensor(0).shape;
      _inputHeight = inputShape[1];
      _inputWidth = inputShape[2];
    } catch (e) {
      debugPrint('❌ Error loading AI model: $e');
    }
  }

  void dispose() {
    _interpreter?.close();
  }

  // --- MANUAL MODE (Still runs normally) ---
  Future<String> predictImage(String imagePath) async {
    if (_interpreter == null || _labels == null) return "Clear Road";
    try {
      File file = File(imagePath);
      final imageData = file.readAsBytesSync();
      img.Image? image = img.decodeImage(imageData);
      if (image == null) return "Clear Road";

      return _runInterpreter(image, _interpreter!, _labels!);
    } catch (e) {
      return "Clear Road";
    }
  }

  // --- HIGH-SPEED DASHCAM MODE ---
  Future<String> predictFrame(CameraImage cameraImage) async {
    if (_interpreter == null || _labels == null) return "Clear Road";

    try {
      // We pass the interpreter pointer address into the background thread!
      // This means 100% of the heavy math happens off the UI thread.
      final String result = await compute(_processAndRunAIInBackground, {
        'format': cameraImage.format.group == ImageFormatGroup.yuv420 ? 'yuv420' : 'bgra8888',
        'width': cameraImage.width,
        'height': cameraImage.height,
        'plane0': cameraImage.planes[0].bytes,
        'plane1': cameraImage.planes.length > 1 ? cameraImage.planes[1].bytes : null,
        'plane2': cameraImage.planes.length > 2 ? cameraImage.planes[2].bytes : null,
        'yRowStride': cameraImage.planes[0].bytesPerRow,
        'uvRowStride': cameraImage.planes.length > 1 ? cameraImage.planes[1].bytesPerRow : 0,
        'uvPixelStride': cameraImage.planes.length > 1 ? cameraImage.planes[1].bytesPerPixel : 0,
        'inputWidth': _inputWidth,
        'inputHeight': _inputHeight,
        'interpreterAddress': _interpreter!.address, // <-- The Magic Pointer!
        'labels': _labels,
      });

      return result;
    } catch (e) {
      debugPrint('❌ Error during frame prediction: $e');
      return "Clear Road";
    }
  }

  // ==========================================
  // BACKGROUND WORKER (ISOLATE)
  // ==========================================
  static String _processAndRunAIInBackground(Map<String, dynamic> params) {
    try {
      img.Image? image;
      String format = params['format'];
      int width = params['width'];
      int height = params['height'];

      if (format == 'yuv420') {
        Uint8List plane0 = params['plane0'];
        Uint8List plane1 = params['plane1'];
        Uint8List plane2 = params['plane2'];
        int yRowStride = params['yRowStride'];
        int uvRowStride = params['uvRowStride'];
        int uvPixelStride = params['uvPixelStride'];

        image = img.Image(width: width, height: height);

        for (int x = 0; x < width; x++) {
          for (int y = 0; y < height; y++) {
            final int uvIndex = uvPixelStride * (x ~/ 2) + uvRowStride * (y ~/ 2);
            final int index = y * yRowStride + x;

            final yp = plane0[index];
            final up = plane1[uvIndex];
            final vp = plane2[uvIndex];

            int r = (yp + vp * 1436 / 1024 - 179).round().clamp(0, 255);
            int g = (yp - up * 46549 / 131072 + 44 - vp * 93604 / 131072 + 91).round().clamp(0, 255);
            int b = (yp + up * 1814 / 1024 - 227).round().clamp(0, 255);

            image.setPixelRgb(x, y, r, g, b);
          }
        }
      } else if (format == 'bgra8888') {
        Uint8List plane0 = params['plane0'];
        image = img.Image.fromBytes(width: width, height: height, bytes: plane0.buffer, order: img.ChannelOrder.bgra);
      }

      if (image == null) return "Clear Road";

      // Reconnect to the AI brain inside this background thread
      int address = params['interpreterAddress'];
      var isolateInterpreter = Interpreter.fromAddress(address);
      List<String> labels = params['labels'];

      return _runInterpreter(image, isolateInterpreter, labels);
    } catch (e) {
      return "Clear Road";
    }
  }

  // ==========================================
  // CORE AI MATH EXECUTION
  // ==========================================
  static String _runInterpreter(img.Image image, Interpreter interpreter, List<String> labels) {
    var inputShape = interpreter.getInputTensor(0).shape;
    int inputHeight = inputShape[1];
    int inputWidth = inputShape[2];

    img.Image resizedImage = img.copyResize(image, width: inputWidth, height: inputHeight);

    var inputBuffer = List.generate(1, (i) =>
        List.generate(inputHeight, (y) =>
            List.generate(inputWidth, (x) {
              final pixel = resizedImage.getPixel(x, y);
              return [pixel.r / 255.0, pixel.g / 255.0, pixel.b / 255.0];
            })
        )
    );

    var outputShape = interpreter.getOutputTensor(0).shape; 
    Object outputBuffer;
    
    if (outputShape.length == 3) {
      outputBuffer = List.generate(outputShape[0], (i) => 
          List.generate(outputShape[1], (j) => List.filled(outputShape[2], 0.0)));
    } else {
      outputBuffer = List.generate(outputShape[0], (i) => List.filled(outputShape[1], 0.0));
    }

    interpreter.run(inputBuffer, outputBuffer);

    double maxConfidence = 0.0;

    if (outputShape.length == 3) {
      var parsedOutput = outputBuffer as List<List<List<double>>>;
      int numBoxes = outputShape[2];
      for (int i = 0; i < numBoxes; i++) {
        double confidence = parsedOutput[0][4][i]; 
        if (confidence > maxConfidence) maxConfidence = confidence;
      }
    } else if (outputShape.length == 2) {
      var parsedOutput = outputBuffer as List<List<double>>;
      maxConfidence = parsedOutput[0][0];
    }

    // INCREASED TO 70% FOR DASHCAM ACCURACY!
    if (maxConfidence > 0.70) {
      return labels.isNotEmpty ? labels[0] : "Pothole";
    } else {
      return "Clear Road";
    }
  }
}