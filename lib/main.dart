import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'screens/login_screen.dart';
import 'services/tflite_service.dart';

/// The main entry point for the Rased (راصد) application.
void main() async {
  // 1. Ensure the Flutter engine is fully initialized before executing any 
  // background asynchronous code (like loading the AI model).
  WidgetsFlutterBinding.ensureInitialized();

  // 2. Boot up the TFLite AI Brain before the UI renders.
  // Wrapped in a try-catch to prevent a total app crash (White Screen of Death)
  // if the model file is missing, corrupted, or too heavy for the device.
  try {
    final aiService = TFLiteService();
    await aiService.initializeModel();
    debugPrint('✅ TFLite Model initialized successfully on startup.');
  } catch (e) {
    debugPrint('❌ CRITICAL: Failed to initialize TFLite Model on startup: $e');
  }

  // 3. Start the application!
  runApp(const RasedApp());
}

/// The root widget of the application.
///
/// Configures the global theme, typography, routing, and initial screen.
class RasedApp extends StatelessWidget {
  const RasedApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Rased | راصد',
      debugShowCheckedModeBanner: false, // Hides the debug banner in the top right
      
      // Global Theme Configuration
      // Applies a deep dark theme with gold/yellow accents across the entire app.
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF121212), // Deep dark background
        
        // Globally standardizes AppBars so you don't have to style them manually everywhere
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF1A1A1A),
          elevation: 0,
          centerTitle: false,
        ),
        
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFFFFD700),   // Primary Gold accent
          secondary: Color(0xFFFFD700), // Secondary Gold accent
        ),
        
        // --- NEW: GLOBAL TYPOGRAPHY ---
        // Overrides the default Android/iOS font with the elegant 'Cairo' font.
        // We apply white colors so it pops perfectly against the dark background.
        textTheme: GoogleFonts.cairoTextTheme(Theme.of(context).textTheme).apply(
          bodyColor: Colors.white,
          displayColor: Colors.white,
        ),
      ),
      
      // The initial screen loaded when the app starts.
      home: const LoginScreen(),
    );
  }
}