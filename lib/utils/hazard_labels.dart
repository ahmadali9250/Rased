import 'package:flutter/material.dart';

import '../services/api_service.dart' show Hazard;

/// Display names and colors for hazard types and statuses, in both languages.
///
/// One place instead of three copies, so status 4 reads the same on the map,
/// in My Reports and in the admin dashboard.
abstract final class HazardLabels {
  // --- Types -----------------------------------------------------------------

  static String typeById(int id, bool isArabic) {
    switch (id) {
      case 1:
        return isArabic ? 'حفرة' : 'Pothole';
      case 2:
        return isArabic ? 'تشقق' : 'Crack';
      case 3:
        return isArabic ? 'خطوط باهتة' : 'Faded Lines';
      case 4:
        return isArabic ? 'مناهل مكسورة' : 'Broken Manhole';
      default:
        return isArabic ? 'نوع غير معروف' : 'Unknown Hazard';
    }
  }

  static const Map<String, String> _typeNamesAr = <String, String>{
    'pothole': 'حفرة',
    'crack': 'تشقق',
    'faded lines': 'خطوط باهتة',
    'broken manhole': 'مناهل مكسورة',
    'street light failure': 'تعطل إنارة الشارع',
    'water leakage': 'تسرب مياه',
    'other': 'أخرى',
  };

  /// Server name when present (translated in Arabic if known), else by id.
  static String type(Hazard hazard, bool isArabic) {
    final apiName = hazard.typeName?.trim();
    if (apiName == null || apiName.isEmpty) {
      return typeById(hazard.typeId, isArabic);
    }
    if (!isArabic) return apiName;
    return _typeNamesAr[apiName.toLowerCase()] ??
        typeById(hazard.typeId, isArabic);
  }

  // --- Statuses --------------------------------------------------------------

  static String statusById(int id, bool isArabic) {
    switch (id) {
      case 1:
        return isArabic ? 'قيد المراجعة' : 'Pending';
      case 2:
        return isArabic ? 'قيد العمل' : 'In Progress';
      case 3:
        return isArabic ? 'محلول' : 'Resolved';
      case 4:
        return isArabic ? 'بلاغ غير صحيح' : 'Incorrect Report';
      default:
        return isArabic ? 'غير معروف' : 'Unknown';
    }
  }

  static const Map<String, String> _statusNamesAr = <String, String>{
    'pending': 'قيد المراجعة',
    'in progress': 'قيد العمل',
    'resolved': 'محلول',
    'incorrect report': 'بلاغ غير صحيح',
    'rejected (ai)': 'بلاغ غير صحيح',
  };

  static String status(Hazard hazard, bool isArabic) {
    final apiName = hazard.statusName?.trim();
    if (apiName == null || apiName.isEmpty) {
      return statusById(hazard.statusId, isArabic);
    }
    if (!isArabic) return apiName;
    return _statusNamesAr[apiName.toLowerCase()] ??
        statusById(hazard.statusId, isArabic);
  }

  static Color statusColor(int statusId) {
    switch (statusId) {
      case 1:
        return const Color(0xFFFFD700);
      case 2:
        return Colors.blueAccent;
      case 3:
        return Colors.greenAccent;
      case 4:
        return Colors.redAccent;
      default:
        return Colors.grey;
    }
  }
}
