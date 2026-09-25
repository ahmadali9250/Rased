import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tareeqi/services/api_service.dart';
import 'package:tareeqi/services/app_language.dart';
import 'package:tareeqi/services/prefs_keys.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AppLanguage.code.value = AppLanguage.english;
  });

  test('set persists the choice and ApiService.currentLanguage mirrors it',
      () async {
    await AppLanguage.set('ar');

    expect(AppLanguage.isArabic, isTrue);
    expect(ApiService.currentLanguage, 'ar');
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(PrefsKeys.language), 'ar');
  });

  test('toggle flips and persists', () async {
    await AppLanguage.toggle();
    expect(AppLanguage.code.value, 'ar');
    await AppLanguage.toggle();
    expect(AppLanguage.code.value, 'en');
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(PrefsKeys.language), 'en');
  });

  test('load prefers the saved value over the device locale', () async {
    SharedPreferences.setMockInitialValues({PrefsKeys.language: 'ar'});
    await AppLanguage.load();
    expect(AppLanguage.code.value, 'ar');
  });

  test('load ignores garbage and falls back to en/ar only', () async {
    SharedPreferences.setMockInitialValues({PrefsKeys.language: 'fr'});
    await AppLanguage.load();
    expect(AppLanguage.code.value, anyOf('en', 'ar'));
  });

  test('unknown codes are coerced to English', () async {
    await AppLanguage.set('xx');
    expect(AppLanguage.code.value, 'en');
  });
}
