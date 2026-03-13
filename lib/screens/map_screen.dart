import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

// --- Mock Data Model ---
class Pothole {
  final String id;
  final LatLng location;
  final int trafficVolume;

  Pothole({required this.id, required this.location, required this.trafficVolume});

  // Calculate severity color based on traffic volume
  Color get severityColor {
    if (trafficVolume > 500) return const Color(0xFFFF3B3B); // High: Red
    if (trafficVolume > 150) return const Color(0xFFFF8800); // Medium: Orange
    return const Color(0xFFFFD700); // Low: Yellow
  }
}

class MapScreen extends StatefulWidget {
  const MapScreen({super.key});

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  // Center of Amman, Jordan
  final LatLng _ammanCenter = const LatLng(31.9539, 35.9106);

  // Mock data representing AI-detected potholes
  final List<Pothole> _potholes = [
    Pothole(id: '1', location: const LatLng(31.958, 35.918), trafficVolume: 800), // Red
    Pothole(id: '2', location: const LatLng(31.950, 35.905), trafficVolume: 300), // Orange
    Pothole(id: '3', location: const LatLng(31.942, 35.915), trafficVolume: 50),  // Yellow
    Pothole(id: '4', location: const LatLng(31.965, 35.925), trafficVolume: 600), // Red
    Pothole(id: '5', location: const LatLng(31.935, 35.895), trafficVolume: 100), // Yellow
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF121212), // Deep dark background
      body: Stack(
        children: [
          // 1. The Interactive Map
          FlutterMap(
            options: MapOptions(
              initialCenter: _ammanCenter,
              initialZoom: 13.5,
            ),
            children: [
              // Dark Mode Map Tiles
              TileLayer(
                urlTemplate: 'https://{s}.basemaps.cartocdn.com/dark_all/{z}/{x}/{y}{r}.png',
                subdomains: const ['a', 'b', 'c'],
              ),
              // Pothole Markers
              MarkerLayer(
                markers: _potholes.map((pothole) {
                  return Marker(
                    point: pothole.location,
                    width: 70,
                    height: 70,
                    child: _buildGlowingMarker(pothole.severityColor),
                  );
                }).toList(),
              ),
            ],
          ),

          // 2. Glassmorphism Top Header
          _buildTopHeader(),

          // 3. Floating "Quick Detect" Button
          _buildBottomFAB(),
        ],
      ),
    );
  }

  // --- Widget Builders ---

  // Builds the layered, glowing circular markers
  Widget _buildGlowingMarker(Color coreColor) {
    return Stack(
      alignment: Alignment.center,
      children: [
        // Outer Glow
        Container(
          width: 70,
          height: 70,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: coreColor.withValues(alpha: 0.15),
          ),
        ),
        // Middle Glimmer
        Container(
          width: 45,
          height: 45,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: coreColor.withValues(alpha: 0.4),
          ),
        ),
        // Inner Core
        Container(
          width: 24,
          height: 24,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: coreColor,
            border: Border.all(color: Colors.white.withValues(alpha: 0.8), width: 1.5),
          ),
        ),
      ],
    );
  }

  // Builds the top glassmorphism navigation bar
  Widget _buildTopHeader() {
    return Positioned(
      top: 50,
      left: 20,
      right: 20,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: Colors.white.withValues(alpha: 0.2)),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  'Tareeqi | طريقي',
                  style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFFFFD700), // Bold Yellow
                    letterSpacing: 1.2,
                  ),
                ),
                CircleAvatar(
                  backgroundColor: Colors.white.withValues(alpha: 0.2),
                  radius: 18,
                  child: const Icon(Icons.person, color: Colors.white, size: 20),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // Builds the bottom action button
  Widget _buildBottomFAB() {
    return Positioned(
      bottom: 40,
      left: 40,
      right: 40,
      child: Container(
        height: 60,
        decoration: BoxDecoration(
          boxShadow: [
            BoxShadow(
              color: const Color(0xFFFFD700).withValues(alpha: 0.3),
              blurRadius: 20,
              spreadRadius: 2,
              offset: const Offset(0, 5),
            )
          ],
        ),
        child: ElevatedButton.icon(
          onPressed: () {
            // TODO: Navigate to Camera/Report Screen
            debugPrint("Quick Detect Tapped");
          },
          style: ElevatedButton.styleFrom(
            backgroundColor: const Color(0xFFFFD700), // Bold Yellow
            foregroundColor: const Color(0xFF121212), // Dark Text
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(30),
            ),
            elevation: 0, // Handled by Container shadow
          ),
          icon: const Icon(Icons.camera_alt, size: 24),
          label: const Text(
            'رصد سريع (Quick Detect)',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
      ),
    );
  }
}