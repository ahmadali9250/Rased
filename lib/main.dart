import 'package:flutter/material.dart';
import 'screens/login_screen.dart';
import 'services/tflite_service.dart';

void main() async {
  // 1. Tell Flutter we are doing background work before starting
  WidgetsFlutterBinding.ensureInitialized();

  // 2. Boot up your AI Brain
  final aiService = TFLiteService();
  await aiService.initializeModel();

  // 3. Start the App!
  runApp(const TareeqiApp());
}

class TareeqiApp extends StatelessWidget {
  const TareeqiApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Rased | راصد',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF121212),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFFFFD700),
          secondary: Color(0xFFFFD700),
        ),
      ),
      home: const LoginScreen(),
    );
  }
}
