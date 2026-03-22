import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'my_reports_screen.dart';
import '../services/api_service.dart';
import 'package:image_picker/image_picker.dart';
import 'package:geolocator/geolocator.dart';
import 'account_screen.dart';

class MapScreen extends StatefulWidget {
  const MapScreen({super.key});

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  int _selectedIndex = 0;
  late String _language = ApiService.currentLanguage;

  void _toggleLanguage() {
    setState(() {
      _language = _language == 'en' ? 'ar' : 'en';
      ApiService.currentLanguage = _language;
    });
  }

  final LatLng _ammanCenter = const LatLng(31.9539, 35.9106);

  // --- REAL API DATA ---
  List<Hazard> _hazards = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _fetchLiveHazards();
  }

  Future<void> _fetchLiveHazards() async {
    final liveData = await ApiService.fetchHazards();
    setState(() {
      _hazards = liveData;
      _isLoading = false;
    });
  }

  // --- GPS LOGIC ---
  Future<Position> _determinePosition() async {
    bool serviceEnabled;
    LocationPermission permission;

    serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      return Future.error('Location services are disabled.');
    }

    permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) {
        return Future.error('Location permissions are denied');
      }
    }

    if (permission == LocationPermission.deniedForever) {
      return Future.error('Location permissions are permanently denied.');
    }

    return await Geolocator.getCurrentPosition();
  }

  @override
  Widget build(BuildContext context) {
    final isArabic = _language == 'ar';

    return Directionality(
      textDirection: isArabic ? TextDirection.rtl : TextDirection.ltr,
      child: Scaffold(
        backgroundColor: const Color(0xFF121212),
        extendBody: true,
        // --- The Centered Floating Button ---
        floatingActionButtonLocation: FloatingActionButtonLocation.centerDocked,
        floatingActionButton: Transform.translate(
          offset: const Offset(0, 20),
          child: SizedBox(
            height: 80,
            width: 80,
            child: FloatingActionButton(
              onPressed: () async {
                final picker = ImagePicker();
                final XFile? photo = await picker.pickImage(
                  source: ImageSource.camera,
                );

                if (photo != null) {
                  if (!context.mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Getting location & uploading...'),
                      backgroundColor: Colors.orange,
                    ),
                  );

                  try {
                    Position position = await _determinePosition();

                    bool success = await ApiService.submitReport(
                      photo: photo,
                      latitude: position.latitude,
                      longitude: position.longitude,
                    );

                    if (!context.mounted) return;
                    if (success) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('✅ Report submitted at your location!'),
                          backgroundColor: Colors.green,
                        ),
                      );
                      _fetchLiveHazards();
                    } else {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('❌ Failed to submit.'),
                          backgroundColor: Colors.red,
                        ),
                      );
                    }
                  } catch (e) {
                    if (!context.mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text('❌ Error: $e'),
                        backgroundColor: Colors.red,
                      ),
                    );
                  }
                }
              },
              backgroundColor: const Color(0xFFFFD700),
              elevation: 4,
              shape: const CircleBorder(),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.camera_alt, color: Colors.black, size: 28),
                  Text(
                    isArabic
                        ? 'رصد'
                        : 'Detect', // <-- Make sure it uses isArabic here!
                    style: const TextStyle(
                      color: Colors.black,
                      fontWeight: FontWeight.bold,
                      fontSize: 10,
                    ),
                  ),
                ],
              ),
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
                _buildBottomNavItem(
                  Icons.map,
                  isArabic ? 'الخريطة' : 'Map',
                  _selectedIndex == 0,
                  () {
                    setState(() => _selectedIndex = 0);
                  },
                ),

                // 2. My Reports Button
                _buildBottomNavItem(
                  Icons.receipt_long,
                  isArabic ? 'بلاغاتي' : 'My Reports',
                  _selectedIndex == 1,
                  () {
                    setState(() => _selectedIndex = 1);
                  },
                ),

                const SizedBox(width: 48),
                // 3. Notifications Button
                _buildBottomNavItem(
                  Icons.notifications_none,
                  isArabic ? 'الإشعارات' : 'Notifications',
                  _selectedIndex == 2,
                  () {
                    setState(() => _selectedIndex = 2);
                  },
                ),

                // 4. Account/Profile Button
                _buildBottomNavItem(
                  Icons.person_outline,
                  isArabic ? 'الحساب' : 'Account',
                  _selectedIndex == 3,
                  () {
                    setState(() => _selectedIndex = 3);
                  },
                ),
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
                    initialZoom: 13.0,
                    minZoom: 5.0,
                    maxZoom: 18.0,
                    cameraConstraint: CameraConstraint.contain(
                      bounds: LatLngBounds(
                        const LatLng(
                          -90,
                          -180,
                        ), // South-West corner of the Earth
                        const LatLng(90, 180), // North-East corner of the Earth
                      ),
                    ),
                  ),
                  children: [
                    TileLayer(
                      urlTemplate:
                          'https://{s}.basemaps.cartocdn.com/dark_all/{z}/{x}/{y}{r}.png',
                      subdomains: const ['a', 'b', 'c'],
                    ),
                    // Live API Markers
                    MarkerLayer(
                      markers: _hazards.map((hazard) {
                        return Marker(
                          point: hazard.location,
                          width: 70,
                          height: 70,
                          child: _buildGlowingMarker(hazard.severityColor),
                        );
                      }).toList(),
                    ),
                  ],
                ),

                // 2. Glassmorphism Top Header
                _buildTopHeader(),

                // 3. Loading Spinner (Only shows when _isLoading is true)
                if (_isLoading)
                  const Center(
                    child: CircularProgressIndicator(color: Color(0xFFFFD700)),
                  ),
              ],
            ),

            // Index 1: My Reports Screen
            const MyReportsScreen(),

            // Index 2: Activity Placeholder
            const Center(
              child: Text(
                'Notifications',
                style: TextStyle(color: Colors.white, fontSize: 24),
              ),
            ),

            // Index 3: Account Screen
            AccountScreen(
              language: _language,
              onLanguageChanged: _toggleLanguage,
            ),
          ],
        ),
      ),
    );
  }

  // --- Widget Builders ---

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
            border: Border.all(
              color: Colors.white.withValues(alpha: 0.8),
              width: 1.5,
            ),
          ),
        ),
      ],
    );
  }

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
  Widget _buildBottomNavItem(
    IconData icon,
    String label,
    bool isSelected,
    VoidCallback onTap,
  ) {
    return InkWell(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            icon,
            color: isSelected ? const Color(0xFFFFD700) : Colors.white54,
            size: 24,
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
