import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import 'package:image_picker/image_picker.dart';

// ==========================================
// 1. DATA MODELS
// ==========================================

/// Represents a road hazard (e.g., Pothole, Crack) retrieved from the database.
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

  /// Factory constructor to safely parse JSON data from the C# backend into a Dart object.
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

  /// Dynamically calculates the severity color of the hazard based on how 
  /// many times it has been detected by users.
  /// 
  /// * Red: High Danger (> 10 detections)
  /// * Yellow: Medium Danger (> 3 detections)
  /// * Green: Low Danger (1-3 detections)
  Color get severityColor {
    if (detectionCount > 10) return Colors.red;
    if (detectionCount > 3) return Colors.yellow;
    return Colors.green;
  }

  /// Smart image URL formatter.
  /// Ensures that relative database paths (e.g., "uploads/pic.jpg") are properly 
  /// appended to the base URL so Flutter can successfully render the network image.
  String? get fullImageUrl {
    if (imagePath == null || imagePath!.isEmpty) return null;
    if (imagePath!.startsWith('http')) return imagePath; 
    return 'https://tareeq-api.onrender.com/$imagePath'; 
  }
}


// ==========================================
// 2. API SERVICE MANAGER
// ==========================================

/// A static service class responsible for all HTTP communication with the Render backend.
class ApiService {
  /// The root URL for the backend API.
  static const String baseUrl = 'https://tareeq-api.onrender.com/api';
  
  // --- IN-MEMORY SESSION STATE ---
  // TODO(Future Enhancement): Replace static variables with 'flutter_secure_storage' 
  // or 'shared_preferences' to persist the user's login session even if the app is closed.
  static String? _token;
  static String? loggedInEmail;
  static String? loggedInRole;

  /// Tracks the user's preferred language globally ('en' or 'ar').
  static String currentLanguage = 'en';

  /// Clears the current user's session data and JWT token.
  static void logout() {
    _token = null;
    loggedInEmail = null;
    loggedInRole = null;
    debugPrint("✅ User logged out. Token cleared.");
  }

  // ------------------------------------------
  // AUTHENTICATION ENDPOINTS
  // ------------------------------------------

  /// Authenticates a user with the backend and retrieves a JWT authorization token.
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
        loggedInRole = data['role']; // e.g., "User", "Admin", "SuperAdmin"
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

  /// Registers a standard citizen account.
  static Future<bool> registerUser(String email, String password, String nationalId) async {
    try {
      final response = await http.post(
        Uri.parse('$baseUrl/Auth/RegisterUser'),
        headers: {'Content-Type': 'application/json', 'Accept-Language': 'en'},
        body: jsonEncode({
          "email": email,
          "password": password,
          "nationalId": nationalId 
        }),
      );

      // 200 OK or 201 Created
      if (response.statusCode == 200 || response.statusCode == 201) {
        debugPrint("✅ Successfully registered citizen!");
        return true;
      }

      debugPrint("❌ Citizen Registration failed: ${response.statusCode} - ${response.body}");
      return false;
    } catch (e) {
      debugPrint("❌ Internet error during registration: $e");
      return false;
    }
  }

  /// Registers a new administrative account.
  /// NOTE: This endpoint strictly requires a SuperAdmin JWT token in the header.
  static Future<bool> registerAdmin(String email, String password, String nationalId) async {
    try {
      final response = await http.post(
        Uri.parse('$baseUrl/Auth/RegisterAdmin'),
        headers: {
          'Content-Type': 'application/json', 
          'Accept-Language': 'en',
          'Authorization': 'Bearer $_token' // SuperAdmin authorization required
        },
        body: jsonEncode({
          "email": email,
          "password": password,
          "nationalId": nationalId 
        }),
      );

      if (response.statusCode == 200 || response.statusCode == 201) {
        debugPrint("✅ Admin successfully registered!");
        return true;
      }

      debugPrint("❌ Admin Registration failed: ${response.statusCode} - ${response.body}");
      return false;
    } catch (e) {
      debugPrint("❌ Internet error during admin registration: $e");
      return false;
    }
  }

  // ------------------------------------------
  // HAZARD MANAGEMENT ENDPOINTS
  // ------------------------------------------

  /// Updates the resolution status of a specific hazard.
  /// * `2` = In Progress
  /// * `3` = Resolved
  /// * `4` = AI False Positive (Error)
  static Future<bool> updateHazardStatus(String hazardId, int newStatusId) async {
    if (_token == null) return false;

    try {
      final response = await http.patch(
        Uri.parse('$baseUrl/Hazards/$hazardId/status/$newStatusId'),
        headers: {
          'Authorization': 'Bearer $_token',
          'Accept-Language': 'en',
          'Content-Type': 'application/json'
        },
      );

      // 200 OK or 204 No Content
      if (response.statusCode == 200 || response.statusCode == 204) {
        debugPrint("✅ Status updated to $newStatusId successfully!");
        return true;
      }

      debugPrint("❌ Failed to update status: ${response.statusCode} - Body: ${response.body}");
      return false;
    } catch (e) {
      debugPrint("❌ Internet error updating status: $e");
      return false;
    }
  }

  /// Fetches the global list of road hazards to populate the interactive map.
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
        // Map JSON list into a strongly-typed Dart List
        return jsonList.map((json) => Hazard.fromJson(json)).toList();
      }
      debugPrint("❌ Failed to fetch hazards: ${response.statusCode}");
      return [];
    } catch (e) {
      debugPrint("❌ Internet error fetching hazards: $e");
      return [];
    }
  }

  /// Submits a new hazard report to the backend.
  /// Utilizes a `MultipartRequest` to successfully encode and transmit the 
  /// user's photographic evidence alongside the geolocation data.
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

      // Apply headers
      request.headers['Authorization'] = 'Bearer $_token';
      request.headers['Accept-Language'] = 'en';

      // Append text fields
      request.fields['Latitude'] = latitude.toString();
      request.fields['Longitude'] = longitude.toString();
      request.fields['TypeId'] = typeId.toString();
      request.fields['StatusID'] = '1'; // Default status: Newly Reported

      // Append the image file as bytes
      final bytes = await photo.readAsBytes();
      request.files.add(
        http.MultipartFile.fromBytes('Image', bytes, filename: photo.name),
      );

      // Transmit the payload
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