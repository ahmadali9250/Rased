import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ==========================================
// 1. DATA MODELS
// ==========================================
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
    if (detectionCount > 10) return Colors.red;
    if (detectionCount > 3) return Colors.yellow;
    return Colors.green;
  }

  String? get fullImageUrl {
    if (imagePath == null || imagePath!.isEmpty) return null;
    if (imagePath!.startsWith('http')) return imagePath; 
    return 'https://tareeq-api.onrender.com/$imagePath'; 
  }
}

// ==========================================
// 2. API SERVICE MANAGER
// ==========================================
class ApiService {
  static const String baseUrl = 'https://tareeq-api.onrender.com/api';
  
  static String? _token;
  static String? loggedInEmail;
  static String? loggedInRole;
  static String currentLanguage = 'en';

  static bool get isLoggedIn => _token != null;

  // --- SESSION PERSISTENCE ---
  
  /// Loads the saved 7-day token from the phone's hard drive on app startup.
  static Future<void> loadSession() async {
    final prefs = await SharedPreferences.getInstance();
    _token = prefs.getString('token');
    loggedInEmail = prefs.getString('email');
    loggedInRole = prefs.getString('role');
    
    if (_token != null) {
      debugPrint("✅ Found saved session! Welcome back $loggedInEmail");
    }
  }

  static Future<void> logout() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.clear(); // Wipes the hard drive memory

    _token = null;
    loggedInEmail = null;
    loggedInRole = null;
    debugPrint("✅ User logged out. Token cleared.");
  }

  // ------------------------------------------
  // AUTHENTICATION ENDPOINTS
  // ------------------------------------------
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

        // Save to hard drive so it survives app restarts!
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('token', _token!);
        await prefs.setString('email', loggedInEmail!);
        await prefs.setString('role', loggedInRole!);

        debugPrint("✅ Successfully logged in! Token saved permanently.");
        return true;
      }
      return false;
    } catch (e) {
      return false;
    }
  }

  // --- UPDATED: Now sends Name and Phone Number to the backend! ---
  static Future<bool> registerUser(String email, String password, String nationalId, String name, String phone) async {
    try {
      final response = await http.post(
        Uri.parse('$baseUrl/Auth/RegisterUser'),
        headers: {'Content-Type': 'application/json', 'Accept-Language': 'en'},
        body: jsonEncode({
          "email": email,
          "password": password,
          "nationalId": nationalId,
          "name": name,
          "phoneNumber": phone
        }),
      );

      if (response.statusCode == 200 || response.statusCode == 201) return true;
      debugPrint("❌ Citizen Registration failed: ${response.body}");
      return false;
    } catch (e) {
      return false;
    }
  }

  static Future<bool> registerAdmin(String email, String password, String nationalId, String name, String phone) async {
    try {
      final response = await http.post(
        Uri.parse('$baseUrl/Auth/RegisterAdmin'),
        headers: {
          'Content-Type': 'application/json', 
          'Accept-Language': 'en',
          'Authorization': 'Bearer $_token' 
        },
        body: jsonEncode({
          "email": email,
          "password": password,
          "nationalId": nationalId,
          "name": name,
          "phoneNumber": phone
        }),
      );

      if (response.statusCode == 200 || response.statusCode == 201) return true;
      return false;
    } catch (e) {
      return false;
    }
  }

  // ------------------------------------------
  // HAZARD MANAGEMENT ENDPOINTS
  // ------------------------------------------
  
  static Future<bool> updateHazardStatus(String hazardId, int newStatusId) async {
    if (_token == null) return false;
    try {
      final response = await http.patch(
        Uri.parse('$baseUrl/Hazards/$hazardId/status/$newStatusId'),
        headers: {'Authorization': 'Bearer $_token', 'Content-Type': 'application/json'},
      );
      if (response.statusCode == 200 || response.statusCode == 204) return true;
      return false;
    } catch (e) {
      return false;
    }
  }

  /// Original: Gets all hazards for the main map.
  static Future<List<Hazard>> fetchHazards() async {
    if (_token == null) return [];
    try {
      final response = await http.get(
        Uri.parse('$baseUrl/Hazards/all'),
        headers: {'Authorization': 'Bearer $_token'},
      );
      if (response.statusCode == 200) {
        List<dynamic> jsonList = jsonDecode(response.body);
        return jsonList.map((json) => Hazard.fromJson(json)).toList();
      }
      return [];
    } catch (e) {
      return [];
    }
  }

  // --- Gets ONLY the hazards reported by the logged-in user. ---
  static Future<List<Hazard>> fetchMyReports() async {
    if (_token == null) return [];
    try {
      final response = await http.get(
        Uri.parse('$baseUrl/Hazards/my-reports'), 
        headers: {'Authorization': 'Bearer $_token'},
      );
      if (response.statusCode == 200) {
        List<dynamic> jsonList = jsonDecode(response.body);
        return jsonList.map((json) => Hazard.fromJson(json)).toList();
      }
      return [];
    } catch (e) {
      return [];
    }
  }

  // --- Gets ONLY unresolved hazards (Status 1 and 2) for the Admin panel. ---
  static Future<List<Hazard>> fetchUnsolvedHazards() async {
    if (_token == null) return [];
    try {
      final response = await http.get(
        Uri.parse('$baseUrl/Hazards/unsolved'), 
        headers: {'Authorization': 'Bearer $_token'},
      );
      if (response.statusCode == 200) {
        List<dynamic> jsonList = jsonDecode(response.body);
        return jsonList.map((json) => Hazard.fromJson(json)).toList();
      }
      return [];
    } catch (e) {
      return [];
    }
  }

  static Future<bool> submitReport({
    required XFile photo, required double latitude, required double longitude, required int typeId,
  }) async {
    if (_token == null) return false;
    try {
      var request = http.MultipartRequest('POST', Uri.parse('$baseUrl/Hazards/report'));
      request.headers['Authorization'] = 'Bearer $_token';
      request.fields['Latitude'] = latitude.toString();
      request.fields['Longitude'] = longitude.toString();
      request.fields['TypeId'] = typeId.toString();
      request.fields['StatusID'] = '1'; 

      final bytes = await photo.readAsBytes();
      request.files.add(http.MultipartFile.fromBytes('Image', bytes, filename: photo.name));

      var response = await request.send();
      if (response.statusCode == 201 || response.statusCode == 200) return true;
      return false;
    } catch (e) {
      return false;
    }
  }
  // إرسال بلاغ بدون صورة (من الكاميرا الذكية)
static Future<bool> submitLocationOnly({...}) async {
  if (_token == null) return false;
  try {
    // ... نفس الكود ...
    if (response.statusCode == 200 || response.statusCode == 201) return true;

    // ❌ فشل — احفظ محلياً
    await OfflineQueue.save({
      'lat': latitude, 'lon': longitude, 'typeId': typeId,
      'time': DateTime.now().toIso8601String(),
    });
    return false;
  } catch (e) {
    // ❌ لا إنترنت — احفظ محلياً
    await OfflineQueue.save({
      'lat': latitude, 'lon': longitude, 'typeId': typeId,
      'time': DateTime.now().toIso8601String(),
    });
    return false;
  }
}
