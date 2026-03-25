import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'my_reports_screen.dart';
import '../services/api_service.dart';
import 'account_screen.dart';
import 'report_damage_screen.dart';
import 'package:geocoding/geocoding.dart';

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
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => const ReportDamageScreen(),
                  ),
                );
              },
              backgroundColor: const Color(0xFFFFD700),
              elevation: 4,
              shape: const CircleBorder(),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.camera_alt, color: Colors.black, size: 28),
                  Text(
                    isArabic ? 'رصد' : 'Detect',
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
                _buildBottomNavItem(
                  Icons.map,
                  isArabic ? 'الخريطة' : 'Map',
                  _selectedIndex == 0,
                  () => setState(() => _selectedIndex = 0),
                ),
                _buildBottomNavItem(
                  Icons.receipt_long,
                  isArabic ? 'بلاغاتي' : 'My Reports',
                  _selectedIndex == 1,
                  () => setState(() => _selectedIndex = 1),
                ),
                const SizedBox(width: 48),
                _buildBottomNavItem(
                  Icons.notifications_none,
                  isArabic ? 'الإشعارات' : 'Notifications',
                  _selectedIndex == 2,
                  () => setState(() => _selectedIndex = 2),
                ),
                _buildBottomNavItem(
                  Icons.person_outline,
                  isArabic ? 'الحساب' : 'Account',
                  _selectedIndex == 3,
                  () => setState(() => _selectedIndex = 3),
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
                        const LatLng(-90, -180),
                        const LatLng(90, 180),
                      ),
                    ),
                  ),
                  children: [
                    TileLayer(
                      urlTemplate: 'https://{s}.basemaps.cartocdn.com/dark_all/{z}/{x}/{y}{r}.png',
                      subdomains: const ['a', 'b', 'c'],
                    ),
                    // Live API Markers
                    MarkerLayer(
                      markers: _hazards.map((hazard) {
                        return Marker(
                          point: hazard.location,
                          width: 70,
                          height: 70,
                          child: GestureDetector(
                            onTap: () {
                              print("📍 Tapped on a hazard!");
                              _showHazardDetails(context, hazard);
                            },
                            child: _buildGlowingMarker(hazard.severityColor),
                          ),
                        );
                      }).toList(),
                    ),
                  ],
                ),

                // 2. Glassmorphism Top Header
                _buildTopHeader(),

                // 3. Loading Spinner
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
        Container(
          width: 70,
          height: 70,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: coreColor.withValues(alpha: 0.15),
          ),
        ),
        Container(
          width: 45,
          height: 45,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: coreColor.withValues(alpha: 0.4),
          ),
        ),
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
            child: const Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  'Rased | راصد',
                  style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFFFFD700),
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

  // --- TRANSLATE ID TO STRING ---
  String _getDamageTypeName(int typeId) {
    switch (typeId) {
      case 1: return _language == 'ar' ? 'حفرة' : 'Pothole';
      case 2: return _language == 'ar' ? 'تشقق' : 'Crack';
      case 3: return _language == 'ar' ? 'خطوط باهتة' : 'Faded Lines';
      default: return _language == 'ar' ? 'أخرى' : 'Other';
    }
  }

  // --- THE POPUP UI ---
  void _showHazardDetails(BuildContext context, Hazard hazard) {
    final isArabic = _language == 'ar';
    final typeName = _getDamageTypeName(hazard.typeId);
    
    // Default to numbers while translate
    String addressText = '${hazard.location.latitude.toStringAsFixed(5)}, ${hazard.location.longitude.toStringAsFixed(5)}';
    bool isTranslatingLocation = true;

    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1E1E1E),
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) {
        return StatefulBuilder(
          builder: (BuildContext context, StateSetter setStateBottomSheet) {
            
            // Fire the translator exactly once
            if (isTranslatingLocation) {
              isTranslatingLocation = false; 
              placemarkFromCoordinates(hazard.location.latitude, hazard.location.longitude)
                .then((placemarks) {
                  if (placemarks.isNotEmpty) {
                    Placemark place = placemarks[0];
                    setStateBottomSheet(() {
                      addressText = "${place.street}, ${place.locality}";
                    });
                  }
                }).catchError((e) {
                  print("Could not translate location.");
                });
            }

            return Directionality(
              textDirection: isArabic ? TextDirection.rtl : TextDirection.ltr,
              child: Padding(
                padding: const EdgeInsets.all(24.0),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // --- HEADER ---
                    Row(
                      children: [
                        Container(
                          width: 16,
                          height: 16,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: hazard.severityColor,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Text(
                          isArabic ? 'تفاصيل البلاغ' : 'Hazard Details',
                          style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.bold),
                        ),
                      ],
                    ),
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 16.0),
                      child: Divider(color: Colors.white24, thickness: 1),
                    ),

                    // --- 📸 NEW IMAGE UI BLOCK 📸 ---
                    if (hazard.fullImageUrl != null)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 20.0),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(14),
                          child: Image.network(
                            hazard.fullImageUrl!,
                            width: double.infinity,
                            height: 200,
                            fit: BoxFit.cover,
                            loadingBuilder: (context, child, loadingProgress) {
                              if (loadingProgress == null) return child;
                              return const SizedBox(
                                height: 200,
                                child: Center(child: CircularProgressIndicator(color: Color(0xFFFFD700))),
                              );
                            },
                            errorBuilder: (context, error, stackTrace) {
                              return Container(
                                height: 200,
                                width: double.infinity,
                                decoration: BoxDecoration(
                                  color: Colors.white.withValues(alpha: 0.05),
                                  borderRadius: BorderRadius.circular(14),
                                  border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
                                ),
                                child: const Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Icon(Icons.broken_image, color: Colors.white38, size: 40),
                                    SizedBox(height: 8),
                                    Text('Image not found on server', style: TextStyle(color: Colors.white38)),
                                  ],
                                ),
                              );
                            },
                          ),
                        ),
                      ),
                    // --- END IMAGE UI BLOCK ---

                    // --- INFO ROWS ---
                    _buildDetailRow(
                      Icons.warning_amber_rounded, 
                      isArabic ? 'نوع الضرر:' : 'Type:', 
                      typeName
                    ),
                    const SizedBox(height: 16),
                    _buildDetailRow(
                      Icons.location_on, 
                      isArabic ? 'الموقع:' : 'Location:', 
                      addressText
                    ),
                    const SizedBox(height: 16),
                    _buildDetailRow(
                      Icons.people_alt_outlined, 
                      isArabic ? 'عدد التبليغات:' : 'Reports Count:', 
                      '${hazard.detectionCount} ${isArabic ? 'مرات' : 'times'}'
                    ),
                    const SizedBox(height: 30),
                  ],
                ),
              ),
            );
          }
        );
      }
    );
  }

  Widget _buildDetailRow(IconData icon, String label, String value) {
    return Row(
      children: [
        Icon(icon, color: const Color(0xFFFFD700), size: 22),
        const SizedBox(width: 12),
        Text(
          label, 
          style: const TextStyle(color: Colors.white70, fontSize: 16)
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            value, 
            style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)
          )
        ),
      ],
    );
  }
}