import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'report_damage_screen.dart';
import 'my_reports_screen.dart';

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
  int _selectedIndex = 0;

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
      extendBody: true, // Lets the map go under the notch
      
      // --- The Centered Floating Button ---
      floatingActionButtonLocation: FloatingActionButtonLocation.centerDocked,
      floatingActionButton: SizedBox(
        height: 80, 
        width: 80,
        child: FloatingActionButton(
          onPressed: () {
            Navigator.push(
              context,
              MaterialPageRoute(builder: (context) => const ReportDamageScreen()),
            );
          },
          backgroundColor: const Color(0xFFFFD700), // Tareeqi Yellow
          elevation: 4,
          shape: const CircleBorder(),
          child: const Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.camera_alt, color: Color(0xFF121212), size: 32),
              SizedBox(height: 2),
              Text(
                'Quick Detect', 
                style: TextStyle(
                  color: Color(0xFF121212), 
                  fontSize: 12, 
                  fontWeight: FontWeight.bold
                ),
              ),
            ],
          ),
        ),
      ),

      // --- The Notched Bottom Bar ---
      bottomNavigationBar: BottomAppBar(
        color: const Color(0xFF1A1A1A), 
        shape: const CircularNotchedRectangle(),
        notchMargin: 8.0, 
        child: SizedBox(
          height: 65,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              // 1. Map Button
              _buildBottomNavItem(Icons.map, 'Map', _selectedIndex == 0, () {
                setState(() => _selectedIndex = 0);
              }),
              
              // 2. My Reports Button (No more Navigator.push!)
              _buildBottomNavItem(Icons.receipt_long, 'My Reports', _selectedIndex == 1, () {
                setState(() => _selectedIndex = 1);
              }),
              
              const SizedBox(width: 48), // Empty space for the center yellow button!
              
              // 3. Notifications Button
              _buildBottomNavItem(Icons.notifications_none, 'Notifications', _selectedIndex == 2, () {
                setState(() => _selectedIndex = 2);
              }),
              
              // 4. Profile Button
              _buildBottomNavItem(Icons.person_outline, 'Profile', _selectedIndex == 3, () {
                setState(() => _selectedIndex = 3);
              }),
            ],
          ),
        ),
      ),
      body: IndexedStack(
        index: _selectedIndex,
        children: [
          Stack(
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
        ],
      ),
        
        // Index 1: My Reports Screen
        const MyReportsScreen(),

        // Index 2: Activity Placeholder
        const Center(child: Text('Notifications', style: TextStyle(color: Colors.white, fontSize: 24))),

          // Index 3: Profile Placeholder
          const Center(child: Text('Profile', style: TextStyle(color: Colors.white, fontSize: 24))),
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
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Text(
                  'Rased | راصد',
                  style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFFFFD700), // Bold Yellow
                    letterSpacing: 1.2,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // --- Bottom Nav Item Helper ---
  Widget _buildBottomNavItem(IconData icon, String label, bool isSelected, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            icon, 
            color: isSelected ? const Color(0xFFFFD700) : Colors.white54, 
            size: 24
          ),
          const SizedBox(height: 4),
          Text(
            label, 
            style: TextStyle(
              color: isSelected ? const Color(0xFFFFD700) : Colors.white54, 
              fontSize: 10,
              fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
            ),
          ),
        ],
      ),
    );
  }
}