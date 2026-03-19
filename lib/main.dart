import 'package:flutter/material.dart';
import 'screens/map_screen.dart'; // Import your new map screen!

void main() {
  runApp(const TareeqiApp());
}

class TareeqiApp extends StatelessWidget {
  const TareeqiApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Rased | راصد',
      debugShowCheckedModeBanner: false, // Removes the little "DEBUG" banner
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF121212),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFFFFD700),
          secondary: Color(0xFFFFD700),
        ),
      ),
      // This tells the app to open the MapScreen first!
      home: const MapScreen(), 
    );
  }
}