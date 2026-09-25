import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'prefs_keys.dart';

/// "Test mode": the live camera runs detection and the report policy exactly
/// as in production, but at the moment a report would be sent it only shows
/// "a report would have been sent here", vibrates and counts it. Nothing is
/// uploaded and no photo is kept.
///
/// Meant for trying the detector against videos at home. Persisted, off by
/// default, survives logout.
abstract final class DryRunMode {
  static final ValueNotifier<bool> enabled = ValueNotifier<bool>(false);

  static Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    enabled.value = prefs.getBool(PrefsKeys.dryRunMode) ?? false;
  }

  static Future<void> set(bool value) async {
    enabled.value = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(PrefsKeys.dryRunMode, value);
  }
}
