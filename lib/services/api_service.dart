import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import 'package:image_picker/image_picker.dart';

// --- 1. The Data Model ---
class Hazard {
  final String id;
  final LatLng location;
  final int typeId;
  final int statusId;
  final int detectionCount;
  final String? imagePath;

  Hazard({
    required this.id,
    required this.location,
    required this.typeId,
    required this.statusId,
    required this.detectionCount,
    this.imagePath,
  });

  factory Hazard.fromJson(Map<String, dynamic> json) {
    return Hazard(
      id: json['id'] ?? '',
      location: LatLng(json['latitude'] ?? 0.0, json['longitude'] ?? 0.0),
      typeId: json['typeId'] ?? 0,
      statusId: json['statusId'] ?? 0,
      detectionCount: json['detectionCount'] ?? 0,
      imagePath: json['imagePath'],
    );
  }

  Color get severityColor {
    if (detectionCount > 10) return const Color(0xFFFF3B3B);
    if (detectionCount > 3) return const Color(0xFFFF8800);
    return const Color(0xFFFFD700);
  }

  // --- SMART IMAGE URL FIXER ---
  // Sometimes databases return "uploads/pic.jpg" instead of the full "https://..." link. 
  // This makes sure Flutter always has a working internet link to download the picture!
  String? get fullImageUrl {
    if (imagePath == null || imagePath!.isEmpty) return null;
    if (imagePath!.startsWith('http')) return imagePath; 
    return 'https://tareeq-api.onrender.com/$imagePath'; 
  }
}

// --- 2. The API Service ---
class ApiService {
  static const String baseUrl = 'https://tareeq-api.onrender.com/api';
  static String? _token;
  static String? loggedInEmail;
  static String? loggedInRole;

  static String currentLanguage = 'en';

  // --- Log Out ---
  static void logout() {
    _token = null;
    loggedInEmail = null;
    loggedInRole = null;
    debugPrint("✅ User logged out. Token cleared.");
  }

  // A. Log in to get the token
  static Future<bool> login(String email, String password) async {
    try {
      final response = await http.post(
        Uri.parse('$baseUrl/Auth/login'),
        headers: {'Content-Type': 'application/json', 'Accept-Language': 'en'},
        body: jsonEncode({"email": email, "password": password}),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        _token = data['token'];
        loggedInEmail = data['email'];
        loggedInRole = data['role'];
        debugPrint("✅ Successfully logged in! Token saved.");
        return true;
      }

      debugPrint("❌ Login failed: ${response.statusCode}");
      return false;
    } catch (e) {
      debugPrint("❌ Internet error during login: $e");
      return false;
    }
  }

  // B. Fetch all hazards for the map
  static Future<List<Hazard>> fetchHazards() async {
    if (_token == null) {
      debugPrint("❌ No token found. Please log in first.");
      return [];
    }

    try {
      final response = await http.get(
        Uri.parse('$baseUrl/Hazards/all'),
        headers: {'Authorization': 'Bearer $_token', 'Accept-Language': 'en'},
      );

      if (response.statusCode == 200) {
        List<dynamic> jsonList = jsonDecode(response.body);
        debugPrint("✅ Fetched ${jsonList.length} hazards from the API!");
        return jsonList.map((json) => Hazard.fromJson(json)).toList();
      }
      debugPrint("❌ Failed to fetch hazards: ${response.statusCode}");
      return [];
    } catch (e) {
      debugPrint("❌ Internet error fetching hazards: $e");
      return [];
    }
  }

  // C. Upload a new hazard report
  static Future<bool> submitReport({
    required XFile photo,
    required double latitude,
    required double longitude,
    required int typeId,
  }) async {
    if (_token == null) {
      debugPrint("❌ No token found. Cannot submit report.");
      return false;
    }

    try {
      var request = http.MultipartRequest(
        'POST',
        Uri.parse('$baseUrl/Hazards/report'),
      );

      request.headers['Authorization'] = 'Bearer $_token';
      request.headers['Accept-Language'] = 'en';

      request.fields['Latitude'] = latitude.toString();
      request.fields['Longitude'] = longitude.toString();
      request.fields['TypeId'] = typeId.toString();
      request.fields['StatusID'] = '1';

      final bytes = await photo.readAsBytes();
      request.files.add(
        http.MultipartFile.fromBytes('Image', bytes, filename: photo.name),
      );

      var response = await request.send();

      if (response.statusCode == 201 || response.statusCode == 200) {
        debugPrint("✅ Report sent successfully!");
        return true;
      }

      debugPrint("❌ Failed to send report: ${response.statusCode}");
      return false;
    } catch (e) {
      debugPrint("❌ Internet error sending report: $e");
      return false;
    }
  }
}
