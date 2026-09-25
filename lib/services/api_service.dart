import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'app_language.dart';
import 'offline_queue.dart';
import 'prefs_keys.dart';
import 'report_events.dart';

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
// 2. FAILURE CODES (translated at display time)
// ==========================================

/// Why a login failed. Screens call [message] with the current language, so
/// the text always matches the UI language at the moment it is shown.
enum AuthFailureKind { server, invalidResponse, http, network }

class AuthFailure {
  const AuthFailure(this.kind, {this.status, this.serverMessage});

  final AuthFailureKind kind;
  final int? status;

  /// Text the backend returned. It already follows `Accept-Language`.
  final String? serverMessage;

  String message(bool isArabic) {
    switch (kind) {
      case AuthFailureKind.server:
        final text = serverMessage?.trim();
        if (text != null && text.isNotEmpty) return text;
        return isArabic
            ? 'الرقم الوطني أو كلمة المرور غير صحيحة'
            : 'Invalid National ID or password';
      case AuthFailureKind.invalidResponse:
        return isArabic
            ? 'استجابة غير صالحة من الخادم'
            : 'Invalid response from server';
      case AuthFailureKind.http:
        return isArabic
            ? 'فشل تسجيل الدخول ($status)'
            : 'Login failed ($status)';
      case AuthFailureKind.network:
        return isArabic
            ? 'تعذر الاتصال بالخادم'
            : 'Unable to connect to server';
    }
  }
}

/// Why a report was not accepted.
enum ReportFailureKind {
  notLoggedIn,
  noLocation,
  outsideJordan,
  http,
  network,
  sessionExpired,
  server,
}

class ReportFailure {
  const ReportFailure(this.kind, {this.status, this.serverMessage});

  final ReportFailureKind kind;
  final int? status;
  final String? serverMessage;

  String message(bool isArabic) {
    switch (kind) {
      case ReportFailureKind.notLoggedIn:
        return isArabic
            ? 'يجب تسجيل الدخول لإرسال بلاغ.'
            : 'You must be logged in to send a report.';
      case ReportFailureKind.noLocation:
        return isArabic
            ? 'لم يتم تحديد الموقع بعد. يرجى تفعيل GPS والمحاولة مجدداً.'
            : 'Location not available yet. Please enable GPS and try again.';
      case ReportFailureKind.outsideJordan:
        return isArabic
            ? 'موقعك خارج نطاق الأردن. تأكد من دقة GPS.'
            : 'Your location appears to be outside Jordan. Check GPS accuracy.';
      case ReportFailureKind.http:
        return isArabic ? 'فشل الإرسال ($status)' : 'Upload failed ($status)';
      case ReportFailureKind.network:
        return isArabic ? 'لا يوجد اتصال بالإنترنت.' : 'No internet connection.';
      case ReportFailureKind.sessionExpired:
        return isArabic
            ? 'انتهت الجلسة، يرجى تسجيل الدخول مجدداً'
            : 'Session expired, please log in again';
      case ReportFailureKind.server:
        final text = serverMessage?.trim();
        if (text != null && text.isNotEmpty) return text;
        return isArabic ? 'فشل الإرسال ($status)' : 'Upload failed ($status)';
    }
  }
}

// ==========================================
// 3. API SERVICE MANAGER
// ==========================================
class ApiService {
  static const String baseUrl =
      'https://rased-app-9lv5h.ondigitalocean.app/api';

  static String? _token;
  static AuthFailure? lastAuthFailure;
  static ReportFailure? lastReportFailure;
  static String? loggedInEmail;
  static String? loggedInRole;

  /// 'ar' or 'en'. Owned by [AppLanguage]; kept here as a getter so existing
  /// `ApiService.currentLanguage == 'ar'` reads keep working.
  static String get currentLanguage => AppLanguage.code.value;

  /// Empty when the backend did not send a value; screens show a translated
  /// "Unknown" in that case.
  static String userName = '';
  static String userPhone = '';
  static String userEmail = '';
  static String userRole = 'User';

  static bool get isLoggedIn => _token != null;

  /// Bumped when the server rejects the saved token (HTTP 401). The session
  /// is already cleared by then; `main.dart` listens and shows the login
  /// screen.
  static final ValueNotifier<int> sessionExpired = ValueNotifier<int>(0);
  static bool _expiring = false;

  static String _requestLanguage(String? language) {
    final value = (language ?? currentLanguage).trim();
    return value.isEmpty ? 'en' : value;
  }

  /// True when [statusCode] is 401. Also clears the session (once) and
  /// notifies [sessionExpired]. Only for endpoints that send the token; a 401
  /// from login means bad credentials, not an expired session.
  static bool _rejectIfUnauthorized(int statusCode) {
    if (statusCode != 401) return false;
    unawaited(_onUnauthorized());
    return true;
  }

  static Future<void> _onUnauthorized() async {
    if (_token == null || _expiring) return;
    _expiring = true;
    try {
      await logout();
      sessionExpired.value = sessionExpired.value + 1;
      debugPrint('⚠️ Session rejected by server (401); user logged out.');
    } finally {
      _expiring = false;
    }
  }

  // --- SESSION PERSISTENCE ---
  static Future<void> loadSession() async {
    final prefs = await SharedPreferences.getInstance();
    _token = prefs.getString(PrefsKeys.token);
    loggedInEmail = prefs.getString(PrefsKeys.email);
    loggedInRole = prefs.getString(PrefsKeys.role);

    userName = _clean(prefs.getString(PrefsKeys.userName));
    userPhone = _clean(prefs.getString(PrefsKeys.userPhone));
    userEmail = _clean(prefs.getString(PrefsKeys.userEmail) ?? loggedInEmail);
    userRole = _clean(prefs.getString(PrefsKeys.userRole) ?? loggedInRole);
    if (userRole.isEmpty) userRole = 'User';

    if (_token != null) {
      debugPrint("✅ Found saved session! Welcome back $loggedInEmail");
    }
  }

  /// Older builds stored the literal "Unknown"; treat it as missing.
  static String _clean(String? value) {
    final v = value?.trim() ?? '';
    return v == 'Unknown' ? '' : v;
  }

  /// Removes only the auth keys. The onboarding flag, language and the
  /// offline report queue survive a logout on purpose.
  static Future<void> logout() async {
    final prefs = await SharedPreferences.getInstance();
    for (final key in PrefsKeys.authKeys) {
      await prefs.remove(key);
    }

    _token = null;
    loggedInEmail = null;
    loggedInRole = null;
    userName = '';
    userPhone = '';
    userEmail = '';
    userRole = 'User';

    debugPrint("✅ User logged out. Token cleared.");
  }

  // ------------------------------------------
  // AUTHENTICATION ENDPOINTS
  // ------------------------------------------
  static Future<bool> login(
    String nationalId,
    String password, {
    String? language,
  }) async {
    lastAuthFailure = null;
    try {
      final response = await http.post(
        Uri.parse('$baseUrl/Auth/login'),
        headers: {
          'Content-Type': 'application/json',
          'Accept-Language': _requestLanguage(language),
        },
        body: jsonEncode({"nationalId": nationalId, "password": password}),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);

        final userData = data['user'] is Map<String, dynamic>
            ? data['user'] as Map<String, dynamic>
            : data;

        final token = (data['token'] ?? data['accessToken'] ?? '').toString();
        if (token.isEmpty) {
          lastAuthFailure = const AuthFailure(AuthFailureKind.invalidResponse);
          return false;
        }
        _token = token;

        loggedInEmail = userData['email']?.toString();
        loggedInRole = userData['role']?.toString();
        userName = _clean(userData['name']?.toString());
        userPhone = _clean(userData['phoneNumber']?.toString());
        userEmail = _clean(userData['email']?.toString());
        userRole = _clean(userData['role']?.toString());
        if (userRole.isEmpty) userRole = 'User';

        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(PrefsKeys.token, token);
        await prefs.setString(PrefsKeys.email, loggedInEmail ?? '');
        await prefs.setString(PrefsKeys.role, loggedInRole ?? '');
        await prefs.setString(PrefsKeys.userName, userName);
        await prefs.setString(PrefsKeys.userPhone, userPhone);
        await prefs.setString(PrefsKeys.userEmail, userEmail);
        await prefs.setString(PrefsKeys.userRole, userRole);

        return true;
      }

      String? serverMessage;
      try {
        final errorData = jsonDecode(response.body);
        if (errorData is Map) {
          serverMessage =
              (errorData['error'] ?? errorData['message'])?.toString();
        }
      } catch (_) {
        // Not JSON; fall through to the generic message.
      }
      lastAuthFailure = serverMessage != null && serverMessage.isNotEmpty
          ? AuthFailure(
              AuthFailureKind.server,
              status: response.statusCode,
              serverMessage: serverMessage,
            )
          : AuthFailure(AuthFailureKind.http, status: response.statusCode);
      return false;
    } catch (e) {
      lastAuthFailure = const AuthFailure(AuthFailureKind.network);
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
      final response = await http.post(
        Uri.parse('$baseUrl/Auth/RegisterUser'),
        headers: {
          'Content-Type': 'application/json',
          'Accept-Language': _requestLanguage(language),
        },
        body: jsonEncode({
          "password": password,
          "nationalId": nationalId,
          "name": name,
          "phoneNumber": phone,
        }),
      );

      if (response.statusCode == 200 || response.statusCode == 201) return true;
      return false;
    } catch (e) {
      return false;
    }
  }

  static Future<bool> registerAdmin(
    String email,
    String password,
    String nationalId,
    String name,
    String phone, {
    String? language,
  }) async {
    if (_token == null) return false;
    try {
      final response = await http.post(
        Uri.parse('$baseUrl/Auth/RegisterAdmin'),
        headers: {
          'Content-Type': 'application/json',
          'Accept-Language': _requestLanguage(language),
          'Authorization': 'Bearer $_token',
        },
        body: jsonEncode({
          "email": email,
          "password": password,
          "nationalId": nationalId,
          "name": name,
          "phoneNumber": phone,
        }),
      );

      if (_rejectIfUnauthorized(response.statusCode)) return false;
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
      final response = await http.patch(
        Uri.parse('$baseUrl/Hazards/$hazardId/status/$newStatusId'),
        headers: {
          'Authorization': 'Bearer $_token',
          'Accept-Language': _requestLanguage(language),
        },
      );
      if (_rejectIfUnauthorized(response.statusCode)) return false;
      if (response.statusCode == 202 ||
          response.statusCode == 200 ||
          response.statusCode == 204) {
        ReportEvents.bump();
        return true;
      }
      return false;
    } catch (e) {
      return false;
    }
  }

  static Future<List<Hazard>> fetchHazards({String? language}) =>
      _fetchHazardList('$baseUrl/Hazards/all', language);

  static Future<List<Hazard>> fetchMyReports({String? language}) =>
      _fetchHazardList('$baseUrl/Hazards/my-reports', language);

  static Future<List<Hazard>> fetchUnsolvedHazards({String? language}) =>
      _fetchHazardList('$baseUrl/Hazards/unsolved', language);

  static Future<List<Hazard>> _fetchHazardList(
    String url,
    String? language,
  ) async {
    if (_token == null) return [];
    try {
      final response = await http.get(
        Uri.parse(url),
        headers: {
          'Authorization': 'Bearer $_token',
          'Accept-Language': _requestLanguage(language),
        },
      );
      if (_rejectIfUnauthorized(response.statusCode)) return [];
      if (response.statusCode == 200) {
        final List<dynamic> jsonList = jsonDecode(response.body);
        return jsonList.map((json) => Hazard.fromJson(json)).toList();
      }
      debugPrint('⚠️ $url returned ${response.statusCode}');
      return [];
    } catch (e) {
      debugPrint('⚠️ $url failed: $e');
      return [];
    }
  }

  // --- Report WITH Photo (Manual Form) ---
  // ✅ Jordan geographic bounding box
  static const double _jordanMinLat = 29.1;
  static const double _jordanMaxLat = 33.4;
  static const double _jordanMinLng = 34.9;
  static const double _jordanMaxLng = 39.3;

  static bool _isInsideJordan(double lat, double lng) {
    return lat >= _jordanMinLat &&
        lat <= _jordanMaxLat &&
        lng >= _jordanMinLng &&
        lng <= _jordanMaxLng;
  }

  static Future<void> _saveOffline({
    required XFile photo,
    required double latitude,
    required double longitude,
    required int typeId,
  }) {
    return OfflineQueue.save({
      'lat': latitude,
      'lon': longitude,
      'typeId': typeId,
      'imagePath': photo.path,
      'time': DateTime.now().toIso8601String(),
    });
  }

  static Future<bool> submitReport({
    required XFile photo,
    required double latitude,
    required double longitude,
    required int typeId,
    String? language,
  }) async {
    lastReportFailure = null;

    if (_token == null) {
      lastReportFailure = const ReportFailure(ReportFailureKind.notLoggedIn);
      await _saveOffline(
        photo: photo,
        latitude: latitude,
        longitude: longitude,
        typeId: typeId,
      );
      return false;
    }

    // ✅ Block invalid or out-of-Jordan coordinates BEFORE hitting the API
    if (latitude == 0.0 && longitude == 0.0) {
      lastReportFailure = const ReportFailure(ReportFailureKind.noLocation);
      return false;
    }

    if (!_isInsideJordan(latitude, longitude)) {
      lastReportFailure = const ReportFailure(ReportFailureKind.outsideJordan);
      return false;
    }

    try {
      var request = http.MultipartRequest(
        'POST',
        Uri.parse('$baseUrl/Hazards/report'),
      );
      request.headers['Authorization'] = 'Bearer $_token';
      request.headers['Accept-Language'] = _requestLanguage(language);
      request.fields['Latitude'] = latitude.toString();
      request.fields['Longitude'] = longitude.toString();
      request.fields['TypeId'] = typeId.toString();
      request.fields['StatusID'] = '1';

      final bytes = await photo.readAsBytes();
      request.files.add(
        http.MultipartFile.fromBytes('Image', bytes, filename: photo.name),
      );

      var response = await request.send();
      var responseData = await response.stream.bytesToString();

      if (response.statusCode == 201 ||
          response.statusCode == 200 ||
          response.statusCode == 409) {
        // 409 = the server merged it into an existing hazard; still a change.
        ReportEvents.bump();
        return true;
      }

      if (_rejectIfUnauthorized(response.statusCode)) {
        // The user has to log in again anyway; do not queue it offline.
        lastReportFailure =
            const ReportFailure(ReportFailureKind.sessionExpired);
        return false;
      }

      // Extract the server's message so the UI can show it
      String? serverMessage;
      try {
        var decoded = jsonDecode(responseData);
        if (decoded is Map) {
          serverMessage =
              (decoded['message'] ?? decoded['error'])?.toString();
        }
      } catch (_) {
        // Not JSON.
      }
      lastReportFailure = serverMessage != null && serverMessage.isNotEmpty
          ? ReportFailure(
              ReportFailureKind.server,
              status: response.statusCode,
              serverMessage: serverMessage,
            )
          : ReportFailure(ReportFailureKind.http, status: response.statusCode);

      debugPrint(
        "❌ submitReport failed (${response.statusCode}): "
        "${serverMessage ?? responseData}",
      );

      // Save locally if it failed
      await _saveOffline(
        photo: photo,
        latitude: latitude,
        longitude: longitude,
        typeId: typeId,
      );
      return false;
    } catch (e) {
      lastReportFailure = const ReportFailure(ReportFailureKind.network);
      debugPrint("❌ submitReport error: $e");
      await _saveOffline(
        photo: photo,
        latitude: latitude,
        longitude: longitude,
        typeId: typeId,
      );
      return false;
    }
  }
}
