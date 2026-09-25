import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tareeqi/services/dry_run_mode.dart';
import 'package:tareeqi/services/prefs_keys.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    DryRunMode.enabled.value = false;
  });

  test('off by default', () async {
    await DryRunMode.load();
    expect(DryRunMode.enabled.value, isFalse);
  });

  test('set persists and load reads it back', () async {
    await DryRunMode.set(true);
    expect(DryRunMode.enabled.value, isTrue);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool(PrefsKeys.dryRunMode), isTrue);

    DryRunMode.enabled.value = false;
    await DryRunMode.load();
    expect(DryRunMode.enabled.value, isTrue);
  });

  test('survives logout (not an auth key)', () {
    expect(PrefsKeys.authKeys, isNot(contains(PrefsKeys.dryRunMode)));
  });
}
