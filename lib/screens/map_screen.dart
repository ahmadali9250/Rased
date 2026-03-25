import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:geocoding/geocoding.dart';
import 'package:flutter_map_marker_cluster/flutter_map_marker_cluster.dart';
import 'package:flutter_map_heatmap/flutter_map_heatmap.dart';

import 'my_reports_screen.dart';
import '../services/api_service.dart';
import 'account_screen.dart';
import 'report_damage_screen.dart';

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

  List<Hazard> _hazards = [];
  bool _isLoading = true;

  // --- 1. NEW FILTER STATE VARIABLES ---
  String _selectedMapStyle = 'satellite'; 
  bool _showHeatmap = true;
  
  // Damage Types
  bool _showPotholes = true;
  bool _showCracks = true;
  bool _showFadedLines = true;
  bool _showBrokenManholes = true;
  
  // Severities
  bool _showHighSeverity = true;
  bool _showMediumSeverity = true;
  bool _showLowSeverity = true;

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

    // --- 2. ADVANCED FILTER LOGIC ---
    List<Hazard> filteredHazards = _hazards.where((h) {
      // Filter by Damage Type
      if (h.typeId == 1 && !_showPotholes) return false;
      if (h.typeId == 2 && !_showCracks) return false;
      if (h.typeId == 3 && !_showFadedLines) return false;
      if (h.typeId == 4 && !_showBrokenManholes) return false; 

      // Filter by Severity (Using the exact math from your database!)
      bool isHigh = h.detectionCount > 10;
      bool isMedium = h.detectionCount > 3 && h.detectionCount <= 10;
      bool isLow = h.detectionCount <= 3;

      // Apply the severity filter
      if (isHigh && !_showHighSeverity) return false;
      if (isMedium && !_showMediumSeverity) return false;
      if (isLow && !_showLowSeverity) return false;

      return true;
    }).toList();

    List<WeightedLatLng> heatmapPoints = filteredHazards.map((h) => WeightedLatLng(h.location, 1.0)).toList();

    // --- 3. MAP STYLES ---
    String currentTileUrl = 'https://mt1.google.com/vt/lyrs=y&x={x}&y={y}&z={z}'; 
    List<String> subdomains = const [];
    
    if (_selectedMapStyle == 'dark') {
      currentTileUrl = 'https://{s}.basemaps.cartocdn.com/dark_all/{z}/{x}/{y}{r}.png';
      subdomains = const ['a', 'b', 'c'];
    } else if (_selectedMapStyle == 'street') {
      currentTileUrl = 'https://mt1.google.com/vt/lyrs=m&x={x}&y={y}&z={z}';
    } else if (_selectedMapStyle == 'cartodb') {
      currentTileUrl = 'https://{s}.basemaps.cartocdn.com/light_all/{z}/{x}/{y}{r}.png';
      subdomains = const ['a', 'b', 'c'];
    }

    return Directionality(
      textDirection: isArabic ? TextDirection.rtl : TextDirection.ltr,
      child: Scaffold(
        backgroundColor: const Color(0xFF121212),
        extendBody: true,
        floatingActionButtonLocation: FloatingActionButtonLocation.centerDocked,
        floatingActionButton: Transform.translate(
          offset: const Offset(0, 20),
          child: SizedBox(
            height: 80, width: 80,
            child: FloatingActionButton(
              onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (context) => const ReportDamageScreen())),
              backgroundColor: const Color(0xFFFFD700),
              elevation: 4, shape: const CircleBorder(),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.camera_alt, color: Colors.black, size: 28),
                  Text(isArabic ? 'رصد' : 'Detect', style: const TextStyle(color: Colors.black, fontWeight: FontWeight.bold, fontSize: 10)),
                ],
              ),
            ),
          ),
        ),
        bottomNavigationBar: BottomAppBar(
          color: const Color(0xFF1A1A1A),
          shape: const CircularNotchedRectangle(),
          notchMargin: 8.0,
          child: SizedBox(
            height: 65,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                _buildBottomNavItem(Icons.map, isArabic ? 'الخريطة' : 'Map', _selectedIndex == 0, () => setState(() => _selectedIndex = 0)),
                _buildBottomNavItem(Icons.receipt_long, isArabic ? 'بلاغاتي' : 'My Reports', _selectedIndex == 1, () => setState(() => _selectedIndex = 1)),
                const SizedBox(width: 48),
                _buildBottomNavItem(Icons.notifications_none, isArabic ? 'الإشعارات' : 'Notifications', _selectedIndex == 2, () => setState(() => _selectedIndex = 2)),
                _buildBottomNavItem(Icons.person_outline, isArabic ? 'الحساب' : 'Account', _selectedIndex == 3, () => setState(() => _selectedIndex = 3)),
              ],
            ),
          ),
        ),
        body: IndexedStack(
          index: _selectedIndex,
          children: [
            Stack(
              children: [
                FlutterMap(
                  options: MapOptions(initialCenter: _ammanCenter, initialZoom: 14.0, minZoom: 5.0, maxZoom: 18.0),
                  children: [
                    TileLayer(urlTemplate: currentTileUrl, subdomains: subdomains),
                    if (_showHeatmap && heatmapPoints.isNotEmpty)
                      HeatMapLayer(
                        heatMapDataSource: InMemoryHeatMapDataSource(data: heatmapPoints),
                        heatMapOptions: HeatMapOptions(
                          gradient: {0.25: Colors.blue, 0.55: Colors.green, 0.85: Colors.yellow, 1.0: Colors.red},
                          minOpacity: 0.2, radius: 40,
                        ),
                      ),
                    MarkerClusterLayerWidget(
                      options: MarkerClusterLayerOptions(
                        maxClusterRadius: 45, size: const Size(40, 40), alignment: Alignment.center, padding: const EdgeInsets.all(50), maxZoom: 16,
                        markers: filteredHazards.map((hazard) {
                          return Marker(
                            point: hazard.location, width: 70, height: 70,
                            child: GestureDetector(onTap: () => _showHazardDetails(context, hazard), child: _buildGlowingMarker(hazard.severityColor)),
                          );
                        }).toList(),
                        builder: (context, markers) {
                          return Container(
                            decoration: BoxDecoration(
                              shape: BoxShape.circle, color: const Color(0xFF4CAF50).withValues(alpha: 0.9),
                              border: Border.all(color: Colors.white, width: 2),
                              boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.5), blurRadius: 4)]
                            ),
                            child: Center(child: Text(markers.length.toString(), style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16))),
                          );
                        },
                      ),
                    ),
                  ],
                ),
                _buildTopHeader(),
                if (_isLoading) const Center(child: CircularProgressIndicator(color: Color(0xFFFFD700))),
              ],
            ),
            const MyReportsScreen(),
            const Center(child: Text('Notifications', style: TextStyle(color: Colors.white, fontSize: 24))),
            AccountScreen(language: _language, onLanguageChanged: _toggleLanguage),
          ],
        ),
      ),
    );
  }

  // --- 4. THE FIXED & EXPANDED FILTER MENU ---
  void _showFilterMenu() {
    final isArabic = _language == 'ar';

    int potholeCount = _hazards.where((h) => h.typeId == 1).length;
    int crackCount = _hazards.where((h) => h.typeId == 2).length;
    int fadedLinesCount = _hazards.where((h) => h.typeId == 3).length;
    int manholeCount = _hazards.where((h) => h.typeId == 4).length;

    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1E1E1E),
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            return Directionality(
              textDirection: isArabic ? TextDirection.rtl : TextDirection.ltr,
              // --- WRAPPED IN SCROLL VIEW TO FIX OVERFLOW ---
              child: SingleChildScrollView( 
                child: Padding(
                  padding: EdgeInsets.only(
                    bottom: MediaQuery.of(context).viewInsets.bottom + 24.0,
                    top: 24.0, left: 24.0, right: 24.0
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(isArabic ? 'طبقات الخريطة' : 'Map Layers', style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.bold)),
                      const Divider(color: Colors.white24, height: 24),
                      
                      // Map Styles
                      RadioListTile<String>(title: Text(isArabic ? 'أقمار اصطناعية' : 'Satellite', style: const TextStyle(color: Colors.white)), activeColor: const Color(0xFFFFD700), value: 'satellite', groupValue: _selectedMapStyle, onChanged: (val) { setModalState(() => _selectedMapStyle = val!); setState(() {}); }),
                      RadioListTile<String>(title: Text(isArabic ? 'خريطة الشوارع' : 'Street Map', style: const TextStyle(color: Colors.white)), activeColor: const Color(0xFFFFD700), value: 'street', groupValue: _selectedMapStyle, onChanged: (val) { setModalState(() => _selectedMapStyle = val!); setState(() {}); }),
                      RadioListTile<String>(title: Text(isArabic ? 'CartoDB (خريطة فاتحة)' : 'CartoDB Positron', style: const TextStyle(color: Colors.white)), activeColor: const Color(0xFFFFD700), value: 'cartodb', groupValue: _selectedMapStyle, onChanged: (val) { setModalState(() => _selectedMapStyle = val!); setState(() {}); }),
                      RadioListTile<String>(title: Text(isArabic ? 'وضع الليل' : 'Dark Mode', style: const TextStyle(color: Colors.white)), activeColor: const Color(0xFFFFD700), value: 'dark', groupValue: _selectedMapStyle, onChanged: (val) { setModalState(() => _selectedMapStyle = val!); setState(() {}); }),

                      const Divider(color: Colors.white24, height: 24),

                      // Severity Levels
                      Text(isArabic ? 'مستوى الخطورة' : 'Severity Levels', style: const TextStyle(color: Colors.white54, fontSize: 14, fontWeight: FontWeight.bold)),
                      CheckboxListTile(
                        title: Row(children: [Container(width: 12, height: 12, decoration: const BoxDecoration(color: Colors.red, shape: BoxShape.circle)), const SizedBox(width: 12), Text(isArabic ? 'خطورة عالية' : 'High Danger (Red)', style: const TextStyle(color: Colors.white))]),
                        activeColor: Colors.red, checkColor: Colors.white, value: _showHighSeverity, onChanged: (val) { setModalState(() => _showHighSeverity = val!); setState(() {}); },
                      ),
                      CheckboxListTile(
                        title: Row(children: [Container(width: 12, height: 12, decoration: const BoxDecoration(color: Colors.yellow, shape: BoxShape.circle)), const SizedBox(width: 12), Text(isArabic ? 'خطورة متوسطة' : 'Medium (Yellow)', style: const TextStyle(color: Colors.white))]),
                        activeColor: Colors.yellow, checkColor: Colors.black, value: _showMediumSeverity, onChanged: (val) { setModalState(() => _showMediumSeverity = val!); setState(() {}); },
                      ),
                      CheckboxListTile(
                        title: Row(children: [Container(width: 12, height: 12, decoration: const BoxDecoration(color: Colors.green, shape: BoxShape.circle)), const SizedBox(width: 12), Text(isArabic ? 'خطورة منخفضة' : 'Low Danger (Green)', style: const TextStyle(color: Colors.white))]),
                        activeColor: Colors.green, checkColor: Colors.white, value: _showLowSeverity, onChanged: (val) { setModalState(() => _showLowSeverity = val!); setState(() {}); },
                      ),

                      const Divider(color: Colors.white24, height: 24),

                      // Damage Types
                      Text(isArabic ? 'أنواع الأضرار' : 'Damage Types', style: const TextStyle(color: Colors.white54, fontSize: 14, fontWeight: FontWeight.bold)),
                      CheckboxListTile(title: Row(children: [const Text('🔥 ', style: TextStyle(fontSize: 18)), Text(isArabic ? 'الخريطة الحرارية' : 'Heatmap', style: const TextStyle(color: Colors.white))]), activeColor: const Color(0xFFFFD700), checkColor: Colors.black, value: _showHeatmap, onChanged: (val) { setModalState(() => _showHeatmap = val!); setState(() {}); }),
                      CheckboxListTile(title: Row(children: [const Text('🕳️ ', style: TextStyle(fontSize: 18)), Text(isArabic ? 'حفرة ($potholeCount)' : 'Potholes ($potholeCount)', style: const TextStyle(color: Colors.white))]), activeColor: const Color(0xFFFFD700), checkColor: Colors.black, value: _showPotholes, onChanged: (val) { setModalState(() => _showPotholes = val!); setState(() {}); }),
                      CheckboxListTile(title: Row(children: [const Text('⚡ ', style: TextStyle(fontSize: 18)), Text(isArabic ? 'تشقق ($crackCount)' : 'Cracks ($crackCount)', style: const TextStyle(color: Colors.white))]), activeColor: const Color(0xFFFFD700), checkColor: Colors.black, value: _showCracks, onChanged: (val) { setModalState(() => _showCracks = val!); setState(() {}); }),
                      CheckboxListTile(title: Row(children: [const Text('〰️ ', style: TextStyle(fontSize: 18)), Text(isArabic ? 'خطوط باهتة ($fadedLinesCount)' : 'Faded Lines ($fadedLinesCount)', style: const TextStyle(color: Colors.white))]), activeColor: const Color(0xFFFFD700), checkColor: Colors.black, value: _showFadedLines, onChanged: (val) { setModalState(() => _showFadedLines = val!); setState(() {}); }),
                      CheckboxListTile(title: Row(children: [const Text('🚧 ', style: TextStyle(fontSize: 18)), Text(isArabic ? 'مناهل مكسورة ($manholeCount)' : 'Broken Manhole ($manholeCount)', style: const TextStyle(color: Colors.white))]), activeColor: const Color(0xFFFFD700), checkColor: Colors.black, value: _showBrokenManholes, onChanged: (val) { setModalState(() => _showBrokenManholes = val!); setState(() {}); }),
                      
                      const SizedBox(height: 30),
                      
                      // --- APPLY & CLOSE BUTTON ---
                      SizedBox(
                        width: double.infinity,
                        height: 50,
                        child: ElevatedButton(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFFFFD700),
                            foregroundColor: Colors.black,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10),
                            ),
                          ),
                          onPressed: () {
                            Navigator.pop(context);
                          },
                          child: Text(
                            isArabic ? 'تطبيق وإغلاق' : 'Apply & Close',
                            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                          ),
                        ),
                      ),

                      const SizedBox(height: 20),
                    ],
                  ),
                ),
              ),
            );
          }
        );
      }
    );
  }

  // --- Widget Builders ---
  Widget _buildGlowingMarker(Color coreColor) {
    return Stack(
      alignment: Alignment.center,
      children: [
        Container(width: 70, height: 70, decoration: BoxDecoration(shape: BoxShape.circle, color: coreColor.withValues(alpha: 0.15))),
        Container(width: 45, height: 45, decoration: BoxDecoration(shape: BoxShape.circle, color: coreColor.withValues(alpha: 0.4))),
        Container(width: 24, height: 24, decoration: BoxDecoration(shape: BoxShape.circle, color: coreColor, border: Border.all(color: Colors.white.withValues(alpha: 0.8), width: 1.5))),
      ],
    );
  }

  Widget _buildTopHeader() {
    return Positioned(
      top: 50, left: 20, right: 20,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
            decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(16), border: Border.all(color: Colors.white.withValues(alpha: 0.2))),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const SizedBox(width: 40), 
                const Text('Rased | راصد', style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: Color(0xFFFFD700), letterSpacing: 1.2)),
                IconButton(icon: const Icon(Icons.layers, color: Colors.white), onPressed: _showFilterMenu),
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
          Icon(icon, color: isSelected ? const Color(0xFFFFD700) : Colors.white54, size: 24),
          const SizedBox(height: 4),
          Text(label, style: TextStyle(color: isSelected ? const Color(0xFFFFD700) : Colors.white54, fontSize: 10, fontWeight: isSelected ? FontWeight.bold : FontWeight.normal)),
        ],
      ),
    );
  }

  String _getDamageTypeName(int typeId) {
    switch (typeId) {
      case 1: return _language == 'ar' ? 'حفرة' : 'Pothole';
      case 2: return _language == 'ar' ? 'تشقق' : 'Crack';
      case 3: return _language == 'ar' ? 'خطوط باهتة' : 'Faded Lines';
      case 4: return _language == 'ar' ? 'مناهل مكسورة' : 'Broken Manhole';
      default: return _language == 'ar' ? 'أخرى' : 'Other';
    }
  }

  void _showHazardDetails(BuildContext context, Hazard hazard) {
    final isArabic = _language == 'ar';
    final typeName = _getDamageTypeName(hazard.typeId);
    String addressText = '${hazard.location.latitude.toStringAsFixed(5)}, ${hazard.location.longitude.toStringAsFixed(5)}';
    bool isTranslatingLocation = true;

    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1E1E1E),
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (context) {
        return StatefulBuilder(
          builder: (BuildContext context, StateSetter setStateBottomSheet) {
            if (isTranslatingLocation) {
              isTranslatingLocation = false; 
              placemarkFromCoordinates(hazard.location.latitude, hazard.location.longitude).then((placemarks) {
                if (placemarks.isNotEmpty) setStateBottomSheet(() => addressText = "${placemarks[0].street}, ${placemarks[0].locality}");
              }).catchError((e) { print("Could not translate location."); });
            }

            return Directionality(
              textDirection: isArabic ? TextDirection.rtl : TextDirection.ltr,
              child: Padding(
                padding: const EdgeInsets.all(24.0),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(width: 16, height: 16, decoration: BoxDecoration(shape: BoxShape.circle, color: hazard.severityColor)),
                        const SizedBox(width: 12),
                        Text(isArabic ? 'تفاصيل البلاغ' : 'Hazard Details', style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.bold)),
                      ],
                    ),
                    const Padding(padding: EdgeInsets.symmetric(vertical: 16.0), child: Divider(color: Colors.white24, thickness: 1)),
                    if (hazard.fullImageUrl != null)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 20.0),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(14),
                          child: Image.network(
                            hazard.fullImageUrl!, width: double.infinity, height: 200, fit: BoxFit.cover,
                            loadingBuilder: (context, child, loadingProgress) {
                              if (loadingProgress == null) return child;
                              return const SizedBox(height: 200, child: Center(child: CircularProgressIndicator(color: Color(0xFFFFD700))));
                            },
                            errorBuilder: (context, error, stackTrace) => Container(
                              height: 200, width: double.infinity,
                              decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.05), borderRadius: BorderRadius.circular(14), border: Border.all(color: Colors.white.withValues(alpha: 0.1))),
                              child: const Column(mainAxisAlignment: MainAxisAlignment.center, children: [Icon(Icons.broken_image, color: Colors.white38, size: 40), SizedBox(height: 8), Text('Image not found on server', style: TextStyle(color: Colors.white38))]),
                            ),
                          ),
                        ),
                      ),
                    _buildDetailRow(Icons.warning_amber_rounded, isArabic ? 'نوع الضرر:' : 'Type:', typeName),
                    const SizedBox(height: 16),
                    _buildDetailRow(Icons.location_on, isArabic ? 'الموقع:' : 'Location:', addressText),
                    const SizedBox(height: 16),
                    _buildDetailRow(Icons.people_alt_outlined, isArabic ? 'عدد التبليغات:' : 'Reports Count:', '${hazard.detectionCount} ${isArabic ? 'مرات' : 'times'}'),
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
        Text(label, style: const TextStyle(color: Colors.white70, fontSize: 16)),
        const SizedBox(width: 8),
        Expanded(child: Text(value, style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold))),
      ],
    );
  }
}