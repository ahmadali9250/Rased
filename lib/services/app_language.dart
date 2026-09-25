import 'package:flutter/widgets.dart';
import 'package:geocoding/geocoding.dart' as geocoding;
import 'package:shared_preferences/shared_preferences.dart';

import 'prefs_keys.dart';

/// The app's UI language ('ar' or 'en'): one source of truth, persisted.
///
/// * First launch: follows the phone locale (Arabic phone → Arabic).
/// * Any manual switch is saved and wins on later launches.
/// * `main.dart` rebuilds `MaterialApp` with the matching `locale`, so
///   Material widgets, date/country pickers and text direction follow.
///
/// Screens read the language in `build` through [AppLanguageContext.isArabic]
/// (a `Localizations` dependency, so open routes rebuild on a switch), and in
/// imperative code through `ApiService.currentLanguage` or [isArabic].
abstract final class AppLanguage {
  static const String arabic = 'ar';
  static const String english = 'en';

  static final ValueNotifier<String> code = ValueNotifier<String>(english);

  static bool get isArabic => code.value == arabic;

  static Locale get locale => Locale(code.value);

  /// Saved preference, else phone locale. Call once before `runApp`.
  static Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(PrefsKeys.language);
    if (saved == arabic || saved == english) {
      code.value = saved!;
    } else {
      final device =
          WidgetsBinding.instance.platformDispatcher.locale.languageCode;
      code.value = device == arabic ? arabic : english;
    }
    await _applyGeocodingLocale();
  }

  static Future<void> set(String lang) async {
    final next = lang == arabic ? arabic : english;
    if (next == code.value) return;
    code.value = next;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(PrefsKeys.language, next);
    await _applyGeocodingLocale();
  }

  static Future<void> toggle() => set(isArabic ? english : arabic);

  /// Reverse geocoding (street names) follows the app language, not the
  /// phone's. Android only; a no-op elsewhere.
  static Future<void> _applyGeocodingLocale() async {
    try {
      await geocoding.setLocaleIdentifier(isArabic ? 'ar_JO' : 'en_US');
    } catch (_) {
      // Unsupported platform or plugin not ready: keep the default.
    }
  }
}

extension AppLanguageContext on BuildContext {
  /// True when the app is showing Arabic. Registers a `Localizations`
  /// dependency, so the widget rebuilds when the language changes.
  bool get isArabic =>
      Localizations.maybeLocaleOf(this)?.languageCode == AppLanguage.arabic;
}
