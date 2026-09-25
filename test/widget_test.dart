// Boot-level widget tests for the app shell (MaterialApp + localization).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tareeqi/main.dart';
import 'package:tareeqi/services/app_language.dart';

void main() {
  tearDown(() => AppLanguage.code.value = AppLanguage.english);

  testWidgets('App boots up test', (WidgetTester tester) async {
    // Provide a blank dummy screen just to satisfy the test
    await tester.pumpWidget(const RasedApp(initialScreen: Scaffold()));
    // Localization delegates load asynchronously; let them finish.
    await tester.pumpAndSettle();

    // Verify the app boots without crashing
    expect(find.byType(Scaffold), findsOneWidget);
  });

  testWidgets('English gives LTR and English Material strings',
      (WidgetTester tester) async {
    AppLanguage.code.value = AppLanguage.english;
    late BuildContext ctx;
    await tester.pumpWidget(RasedApp(
      initialScreen: Builder(builder: (c) {
        ctx = c;
        return const Scaffold();
      }),
    ));
    await tester.pumpAndSettle();

    expect(Directionality.of(ctx), TextDirection.ltr);
    expect(MaterialLocalizations.of(ctx).okButtonLabel, 'OK');
    expect(ctx.isArabic, isFalse);
  });

  testWidgets('Arabic gives RTL and Arabic Material strings',
      (WidgetTester tester) async {
    AppLanguage.code.value = AppLanguage.arabic;
    late BuildContext ctx;
    await tester.pumpWidget(RasedApp(
      initialScreen: Builder(builder: (c) {
        ctx = c;
        return const Scaffold();
      }),
    ));
    await tester.pumpAndSettle();

    expect(Directionality.of(ctx), TextDirection.rtl);
    expect(MaterialLocalizations.of(ctx).okButtonLabel, isNot('OK'));
    expect(ctx.isArabic, isTrue);
  });

  testWidgets('switching the language re-localizes open routes',
      (WidgetTester tester) async {
    AppLanguage.code.value = AppLanguage.english;
    late BuildContext ctx;
    await tester.pumpWidget(RasedApp(
      initialScreen: Builder(builder: (c) {
        ctx = c;
        return const Scaffold();
      }),
    ));
    await tester.pumpAndSettle();
    expect(Directionality.of(ctx), TextDirection.ltr);

    AppLanguage.code.value = AppLanguage.arabic;
    await tester.pumpAndSettle();
    expect(Directionality.of(ctx), TextDirection.rtl);
  });
}
