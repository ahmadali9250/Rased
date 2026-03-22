import 'package:flutter/material.dart';
import 'screens/login_screen.dart';

void main() {
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
