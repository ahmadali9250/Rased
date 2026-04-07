import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'screens/login_screen.dart';
import 'screens/map_screen.dart';
import 'services/tflite_service.dart';
import 'services/api_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 1. Load the saved session from the phone's hard drive!
  await ApiService.loadSession();

  // 2. Boot up the TFLite AI Brain
  try {
    final aiService = TFLiteService();
    await aiService.initializeModel();
    debugPrint('✅ TFLite Model initialized successfully on startup.');
  } catch (e) {
    debugPrint('❌ CRITICAL: Failed to initialize TFLite Model on startup: $e');
  }

  runApp(const RasedApp());
}

class RasedApp extends StatelessWidget {
  const RasedApp({super.key});

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
        textTheme: GoogleFonts.cairoTextTheme(Theme.of(context).textTheme).apply(
          bodyColor: Colors.white,
          displayColor: Colors.white,
        ),
      ),
      
      // --- SKIP LOGIN IF TOKEN EXISTS ---
      home: ApiService.isLoggedIn ? const MapScreen() : const LoginScreen(),
    );
  }
}