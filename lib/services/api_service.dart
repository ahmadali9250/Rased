import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'offline_queue.dart';

// ==========================================
// 1. DATA MODELS
// ==========================================
class Hazard {
  final String id;
  final LatLng location;
  final int typeId;
  final String? typeName;
  final int statusId;
  final String? statusName;
  final int detectionCount;
  final String? imagePath;

  Hazard({
    required this.id,
    required this.location,
    required this.typeId,
    this.typeName,
    required this.statusId,
    this.statusName,
    required this.detectionCount,
    this.imagePath,
  });

  factory Hazard.fromJson(Map<String, dynamic> json) {
    return Hazard(
      id: json['id'] ?? '',
      location: LatLng(json['latitude'] ?? 0.0, json['longitude'] ?? 0.0),
      typeId: json['typeId'] ?? 0,
      typeName: json['typeName']?.toString(),
      statusId: json['statusID'] ?? json['statusId'] ?? 0,
      statusName: json['statusName']?.toString(),
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
  static const String baseUrl = 'https://rased-app-9lv5h.ondigitalocean.app/api';
  
  static String? _token;
  static String? lastAuthError;
  static String? loggedInEmail;
  static String? loggedInRole;
  static String currentLanguage = 'en';

  // ✅ NEW VARIABLES for Profile Screen
  static String userName = "Unknown";
  static String userPhone = "Unknown";
  static String userEmail = "Unknown";
  static String userRole = "User";

  static bool get isLoggedIn => _token != null;

  // --- SESSION PERSISTENCE ---
  
  static Future<void> loadSession() async {
    final prefs = await SharedPreferences.getInstance();
    _token = prefs.getString('token');
    loggedInEmail = prefs.getString('email');
    loggedInRole = prefs.getString('role');
    
    // Load new profile variables from cache if available
    userName = prefs.getString('userName') ?? "Unknown";
    userPhone = prefs.getString('userPhone') ?? "Unknown";
    userEmail = prefs.getString('userEmail') ?? loggedInEmail ?? "Unknown";
    userRole = prefs.getString('userRole') ?? loggedInRole ?? "User";
    
    if (_token != null) {
      debugPrint("✅ Found saved session! Welcome back $loggedInEmail");
    }
  }

  static Future<void> logout() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.clear();

    _token = null;
    loggedInEmail = null;
    loggedInRole = null;
    userName = "Unknown";
    userPhone = "Unknown";
    userEmail = "Unknown";
    userRole = "User";

    debugPrint("✅ User logged out. Token cleared.");
  }

  // ------------------------------------------
  // AUTHENTICATION ENDPOINTS
  // ------------------------------------------
  static Future<bool> login(String nationalId, String password, {String? language}) async {
    lastAuthError = null;
    try {
      final requestLanguage = (language ?? currentLanguage).trim().isEmpty
          ? 'en'
          : (language ?? currentLanguage).trim();

      final response = await http.post(
        Uri.parse('$baseUrl/Auth/login'),
        headers: {
          'Content-Type': 'application/json',
          'Accept-Language': requestLanguage,
        },
        body: jsonEncode({
          "nationalId": nationalId,
          "password": password,
        }),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);

        // Support both flat and nested response shapes.
        final userData = data['user'] is Map<String, dynamic>
            ? data['user'] as Map<String, dynamic>
            : data;

        _token = (data['token'] ?? data['accessToken'] ?? '').toString();
        if (_token == null || _token!.isEmpty) {
          lastAuthError = 'Invalid login response: missing token.';
          return false;
        }

        loggedInEmail = userData['email']?.toString();
        loggedInRole = userData['role']?.toString(); 
        
        // ✅ NEW LINES: Read and save the profile data from the backend
        userName = userData['name']?.toString() ?? "Unknown";
        userPhone = userData['phoneNumber']?.toString() ?? "Unknown";
        userEmail = userData['email']?.toString() ?? "Unknown";
        userRole = userData['role']?.toString() ?? "User";

        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('token', _token!);
        await prefs.setString('email', loggedInEmail ?? '');
        await prefs.setString('role', loggedInRole ?? '');
        
        // Cache the new variables so they survive app restarts
        await prefs.setString('userName', userName);
        await prefs.setString('userPhone', userPhone);
        await prefs.setString('userEmail', userEmail);
        await prefs.setString('userRole', userRole);

        debugPrint("✅ Successfully logged in! Token saved permanently.");
        return true;
      }

      try {
        final errorData = jsonDecode(response.body);
        if (errorData is Map && errorData['error'] != null) {
          lastAuthError = errorData['error'].toString();
        } else {
          lastAuthError = 'Login failed (${response.statusCode}).';
        }
      } catch (_) {
        lastAuthError = 'Login failed (${response.statusCode}).';
      }

      return false;
    } catch (e) {
      lastAuthError = 'Unable to connect to server.';
      return false;
    }
  }

  static Future<bool> registerUser(
    String password,
    String nationalId,
    String name,
    String phone, {
    String? language,
  }) async {
    try {
      final requestLanguage = (language ?? currentLanguage).trim().isEmpty
          ? 'en'
          : (language ?? currentLanguage).trim();

      final response = await http.post(
        Uri.parse('$baseUrl/Auth/RegisterUser'),
        headers: {
          'Content-Type': 'application/json',
          'Accept-Language': requestLanguage,
        },
        body: jsonEncode({
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
  
  static Future<bool> updateHazardStatus(
    String hazardId,
    int newStatusId, {
    String? language,
  }) async {
    if (_token == null) return false;
    try {
      final requestLanguage = (language ?? currentLanguage).trim().isEmpty
          ? 'en'
          : (language ?? currentLanguage).trim();

      final response = await http.patch(
        Uri.parse('$baseUrl/Hazards/$hazardId/status/$newStatusId'),
        headers: {
          'Authorization': 'Bearer $_token',
          'Accept-Language': requestLanguage,
        },
      );
      if (response.statusCode == 202 || response.statusCode == 200 || response.statusCode == 204) {
        return true;
      }
      return false;
    } catch (e) {
      return false;
    }
  }

  static Future<List<Hazard>> fetchHazards({String? language}) async {
    if (_token == null) return [];
    try {
      final requestLanguage = (language ?? currentLanguage).trim().isEmpty
          ? 'en'
          : (language ?? currentLanguage).trim();

      final response = await http.get(
        Uri.parse('$baseUrl/Hazards/all'),
        headers: {
          'Authorization': 'Bearer $_token',
          'Accept-Language': requestLanguage,
        },
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

  static Future<List<Hazard>> fetchMyReports({String? language}) async {
    if (_token == null) return [];
    try {
      final requestLanguage = (language ?? currentLanguage).trim().isEmpty
          ? 'en'
          : (language ?? currentLanguage).trim();

      final response = await http.get(
        Uri.parse('$baseUrl/Hazards/my-reports'), 
        headers: {
          'Authorization': 'Bearer $_token',
          'Accept-Language': requestLanguage,
        },
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

  static Future<List<Hazard>> fetchUnsolvedHazards({String? language}) async {
    if (_token == null) return [];
    try {
      final requestLanguage = (language ?? currentLanguage).trim().isEmpty
          ? 'en'
          : (language ?? currentLanguage).trim();

      final response = await http.get(
        Uri.parse('$baseUrl/Hazards/unsolved'), 
        headers: {
          'Authorization': 'Bearer $_token',
          'Accept-Language': requestLanguage,
        },
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

  // --- Report WITH Photo (Manual Form) ---
  static Future<bool> submitReport({
    required XFile photo,
    required double latitude,
    required double longitude,
    required int typeId,
    String? language,
  }) async {
    if (_token == null) {
      await OfflineQueue.save({
        'lat': latitude,
        'lon': longitude,
        'typeId': typeId,
        'imagePath': photo.path,
        'time': DateTime.now().toIso8601String(),
      });
      return false;
    }
    try {
      final requestLanguage = (language ?? currentLanguage).trim().isEmpty
          ? 'en'
          : (language ?? currentLanguage).trim();

      var request = http.MultipartRequest('POST', Uri.parse('$baseUrl/Hazards/report'));
      request.headers['Authorization'] = 'Bearer $_token';
      request.headers['Accept-Language'] = requestLanguage;
      request.fields['Latitude'] = latitude.toString();
      request.fields['Longitude'] = longitude.toString();
      request.fields['TypeId'] = typeId.toString();
      request.fields['StatusID'] = '1'; 

      final bytes = await photo.readAsBytes();
      request.files.add(http.MultipartFile.fromBytes('Image', bytes, filename: photo.name));

      var response = await request.send();
      if (response.statusCode == 201 || response.statusCode == 200 || response.statusCode == 409) return true;

      // ❌ Upload failed (e.g., server returned an error) - Save locally
      debugPrint("❌ submitReport failed with status: ${response.statusCode}");
      await OfflineQueue.save({
        'lat': latitude, 'lon': longitude, 'typeId': typeId,
        'imagePath': photo.path, // Save image path to upload later
        'time': DateTime.now().toIso8601String(),
      });
      return false;
    } catch (e) {
      // ❌ No internet or other error - Save locally
      debugPrint("❌ submitReport error: $e");
      await OfflineQueue.save({
        'lat': latitude, 'lon': longitude, 'typeId': typeId,
        'imagePath': photo.path, // Save image path to upload later
        'time': DateTime.now().toIso8601String(),
      });
      return false;
    }
  }

  // Send report without photo (from smart camera)
  static Future<bool> submitLocationOnly({
    required double latitude,
    required double longitude,
    required int typeId,
  }) async {
    if (_token == null) {
      await OfflineQueue.save({
        'lat': latitude,
        'lon': longitude,
        'typeId': typeId,
        'time': DateTime.now().toIso8601String(),
      });
      return false;
    }
    try {
      final response = await http.post(
        Uri.parse('$baseUrl/Hazards/report-location'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $_token',
        },
        body: jsonEncode({
          'Latitude': latitude,
          'Longitude': longitude,
          'TypeId': typeId,
          'StatusID': 1,
        }),
      );

      if (response.statusCode == 200 || response.statusCode == 201 || response.statusCode == 409) return true;

      // ❌ Failed — save locally
      await OfflineQueue.save({
        'lat': latitude, 'lon': longitude, 'typeId': typeId,
        'time': DateTime.now().toIso8601String(),
      });
      return false;
    } catch (e) {
      // ❌ No internet — save locally
      await OfflineQueue.save({
        'lat': latitude, 'lon': longitude, 'typeId': typeId,
        'time': DateTime.now().toIso8601String(),
      });
      return false;
    }
  }
}