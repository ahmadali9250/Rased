import 'dart:async';

import 'package:country_picker/country_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'screens/login_screen.dart';
import 'screens/map_screen.dart';
import 'screens/onboarding_screen.dart';
import 'services/api_service.dart';
import 'services/app_language.dart';
import 'services/dry_run_mode.dart';
import 'services/prefs_keys.dart';
import 'services/tflite_service.dart';

/// Root navigator, so services can send the user to the login screen when
/// the server rejects the saved token.
final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

/// Root messenger: SnackBars survive route changes (e.g. session expiry).
final GlobalKey<ScaffoldMessengerState> scaffoldMessengerKey =
    GlobalKey<ScaffoldMessengerState>();

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 1. Language (saved choice, else phone locale) and the saved session.
  await AppLanguage.load();
  await DryRunMode.load();
  await ApiService.loadSession();

  // Open SharedPreferences to check onboarding status
  final prefs = await SharedPreferences.getInstance();

  // 2. Pre-warm the shared AI worker in the background. Not awaited: the
  //    worker runs in its own isolate, so the first screen appears at once
  //    and the camera screen finds the model already loaded.
  unawaited(
    TFLiteService.instance.initialize().catchError((Object e) {
      debugPrint('❌ AI worker failed to start: $e');
    }),
  );

  // 3. Check if they have seen the onboarding screen. Older builds wrote the
  //    flag under a different key; honour both so nobody sees it twice.
  final bool hasSeenOnboarding =
      prefs.getBool(PrefsKeys.hasSeenOnboarding) ??
          prefs.getBool(PrefsKeys.legacyHasSeenOnboarding) ??
          false;

  // 4. Determine the starting screen based on their history
  Widget startingScreen;
  if (!hasSeenOnboarding) {
    startingScreen = const OnboardingScreen(); // First time ever opening the app
  } else if (ApiService.isLoggedIn) {
    startingScreen = const MapScreen(); // Returning user, already logged in
  } else {
    startingScreen = const LoginScreen(); // Returning user, but needs to log in
  }

  // Pass the chosen screen into the app
  runApp(RasedApp(initialScreen: startingScreen));
}

class RasedApp extends StatefulWidget {
  final Widget initialScreen; // Variable to hold the starting screen

  // Require the initialScreen in the constructor
  const RasedApp({super.key, required this.initialScreen});

  @override
  State<RasedApp> createState() => _RasedAppState();
}

class _RasedAppState extends State<RasedApp> {
  @override
  void initState() {
    super.initState();
    ApiService.sessionExpired.addListener(_onSessionExpired);
  }

  @override
  void dispose() {
    ApiService.sessionExpired.removeListener(_onSessionExpired);
    super.dispose();
  }

  /// The server rejected the saved token: the session is already cleared,
  /// so drop every route and show the login screen with a short note.
  void _onSessionExpired() {
    final isArabic = AppLanguage.isArabic;
    navigatorKey.currentState?.pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const LoginScreen()),
      (_) => false,
    );
    scaffoldMessengerKey.currentState?.showSnackBar(
      SnackBar(
        content: Text(
          isArabic
              ? 'انتهت الجلسة، يرجى تسجيل الدخول مجدداً'
              : 'Session expired, please log in again',
        ),
        backgroundColor: Colors.orange,
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Rebuilding MaterialApp with a new `locale` re-localizes every Material
    // widget (date pickers, back arrows, text direction) in one place.
    return ValueListenableBuilder<String>(
      valueListenable: AppLanguage.code,
      builder: (_, lang, _) {
        return MaterialApp(
          title: 'Rased | راصد',
          debugShowCheckedModeBanner: false,
          navigatorKey: navigatorKey,
          scaffoldMessengerKey: scaffoldMessengerKey,

          // --- LOCALIZATION ---
          locale: Locale(lang),
          supportedLocales: const [Locale('en'), Locale('ar')],
          localizationsDelegates: const [
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
            CountryLocalizations.delegate,
          ],

          theme: ThemeData.dark().copyWith(
            scaffoldBackgroundColor: const Color(0xFF121212),
            appBarTheme: const AppBarTheme(
              backgroundColor: Color(0xFF1A1A1A),
              elevation: 0,
              centerTitle: false,
            ),
            colorScheme: const ColorScheme.dark(
              primary: Color(0xFFFFD700),
              secondary: Color(0xFFFFD700),
            ),
            textTheme: GoogleFonts.cairoTextTheme().apply(
              bodyColor: Colors.white,
              displayColor: Colors.white,
            ),
          ),

          // --- START ON THE CORRECT SCREEN ---
          home: widget.initialScreen, // Use the calculated screen here
        );
      },
    );
  }
}
