import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import 'dart:io';
import 'package:image_picker/image_picker.dart';

// --- 1. The Data Model (Matches your friend's HazardGetDto) ---
class Hazard {
  final String id;
  final LatLng location;
  final int typeId;
  final int statusId;
  final int detectionCount;

  Hazard({
    required this.id,
    required this.location,
    required this.typeId,
    required this.statusId,
    required this.detectionCount,
  });

  // Convert the JSON from the API into a Dart Object
  factory Hazard.fromJson(Map<String, dynamic> json) {
    return Hazard(
      id: json['id'] ?? '',
      location: LatLng(json['latitude'] ?? 0.0, json['longitude'] ?? 0.0),
      typeId: json['typeId'] ?? 0,
      statusId: json['statusId'] ?? 0,
      detectionCount: json['detectionCount'] ?? 0,
    );
  }

  // Calculate severity color based on how many times it was detected!
  Color get severityColor {
    if (detectionCount > 10) return const Color(0xFFFF3B3B); // High: Red
    if (detectionCount > 3) return const Color(0xFFFF8800);  // Medium: Orange
    return const Color(0xFFFFD700);                          // Low: Yellow
  }
}

// --- 2. The API Service ---
class ApiService {
  static const String baseUrl = 'https://tareeq-api.onrender.com/api';
  static String? _token; // Holds our secret key after logging in

  // A. Log in to get the token
  static Future<bool> login() async {
    try {
      final response = await http.post(
        Uri.parse('$baseUrl/Auth/login'),
        headers: {
          'Content-Type': 'application/json',
          'Accept-Language': 'en',
        },
        body: jsonEncode({
          "email": "abed@user.com",
          "passwordHashed": "1234"
        }),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        _token = data['token'];
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
    // If we don't have a token, try to log in first!
    if (_token == null) {
      bool loggedIn = await login();
      if (!loggedIn) return []; // Return empty list if login completely fails
    }

    try {
      final response = await http.get(
        Uri.parse('$baseUrl/Hazards/all'),
        headers: {
          'Authorization': 'Bearer $_token', // Send the secret key!
          'Accept-Language': 'en',
        },
      );

      if (response.statusCode == 200) {
        // Convert the JSON text into a list of Hazard objects
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

  // C. Upload a new hazard report (Web & Mobile Safe!)
  static Future<bool> submitReport({
    required XFile photo, // Changed from File to XFile
    required double latitude,
    required double longitude,
  }) async {
    if (_token == null) await login();

    try {
      var request = http.MultipartRequest('POST', Uri.parse('$baseUrl/Hazards/report'));
      
      request.headers['Authorization'] = 'Bearer $_token';
      request.headers['Accept-Language'] = 'en';

      request.fields['Latitude'] = latitude.toString();
      request.fields['Longitude'] = longitude.toString();
      request.fields['TypeId'] = '1'; 
      request.fields['StatusID'] = '1'; 

      // Read the file as bytes (This is the magic line that fixes it for the Web!)
      final bytes = await photo.readAsBytes();
      request.files.add(http.MultipartFile.fromBytes(
        'Image', 
        bytes, 
        filename: photo.name,
      ));

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