import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'screens/login_screen.dart';
import 'screens/map_screen.dart';
import 'screens/onboarding_screen.dart';
import 'services/tflite_service.dart';
import 'services/api_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 1. Load the saved session from the phone's hard drive!
  await ApiService.loadSession();
  
  // Open SharedPreferences to check onboarding status
  final prefs = await SharedPreferences.getInstance();

  // 2. Boot up the TFLite AI Brain
  try {
    final aiService = TFLiteService();
    await aiService.initializeModel();
    debugPrint('✅ TFLite Model initialized successfully on startup.');
  } catch (e) {
    debugPrint('❌ CRITICAL: Failed to initialize TFLite Model on startup: $e');
  }

  // 3. Check if they have seen the onboarding screen
  bool hasSeenOnboarding = prefs.getBool('hasSeenOnboarding') ?? false;

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

class RasedApp extends StatelessWidget {
  final Widget initialScreen; // Variable to hold the starting screen

  // Require the initialScreen in the constructor
  const RasedApp({super.key, required this.initialScreen});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Rased | راصد',
      debugShowCheckedModeBanner: false, 
      
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
      home: initialScreen, // Use the calculated screen here
    );
  }
}