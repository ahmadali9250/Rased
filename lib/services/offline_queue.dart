import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

class OfflineQueue {
  static const _key = 'pending_reports';

  static Future<void> save(Map<String, dynamic> report) async {
    final prefs = await SharedPreferences.getInstance();
    final list = await getAll();
    list.add(report);
    await prefs.setString(_key, jsonEncode(list));
  }

  static Future<List<Map<String, dynamic>>> getAll() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null) return [];
    return List<Map<String, dynamic>>.from(jsonDecode(raw));
  }

  static Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key);
  }

  static Future<int> getPendingCount() async {
    return (await getAll()).length;
  }
}