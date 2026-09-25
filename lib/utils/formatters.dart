import 'package:geocoding/geocoding.dart';

/// Small text helpers shared by several screens.

/// "Street, City[, Country]" from a placemark, skipping null/empty parts so
/// the UI never shows "null, null".
String formatPlacemark(Placemark place, {bool withCountry = false}) {
  final parts = <String>[
    place.street ?? '',
    place.locality ?? place.subAdministrativeArea ?? '',
    if (withCountry) place.country ?? '',
  ].map((p) => p.trim()).where((p) => p.isNotEmpty && p != 'null').toList();
  return parts.join(', ');
}

/// "1 time" / "3 times", with Arabic plural forms.
String timesLabel(int count, bool isArabic) {
  if (!isArabic) return count == 1 ? '1 time' : '$count times';
  if (count == 1) return 'مرة واحدة';
  if (count == 2) return 'مرتان';
  if (count >= 3 && count <= 10) return '$count مرات';
  return '$count مرة';
}

String unknownLabel(bool isArabic) => isArabic ? 'غير معروف' : 'Unknown';

/// Backend role value → display label.
String roleLabel(String role, bool isArabic) {
  switch (role.trim().toLowerCase()) {
    case 'user':
      return isArabic ? 'مستخدم' : 'User';
    case 'admin':
      return isArabic ? 'مسؤول' : 'Admin';
    case 'superadmin':
      return isArabic ? 'مسؤول رئيسي' : 'Super Admin';
    default:
      return role.trim().isEmpty ? unknownLabel(isArabic) : role;
  }
}
