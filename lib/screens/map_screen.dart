import 'dart:ui';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:geocoding/geocoding.dart'; 
import 'package:geolocator/geolocator.dart'; 
import 'package:flutter_map_marker_cluster/flutter_map_marker_cluster.dart';
import 'package:flutter_map_heatmap/flutter_map_heatmap.dart';

import 'my_reports_screen.dart';
import '../services/api_service.dart';
import 'account_screen.dart';
import 'report_damage_screen.dart';
import 'live_camera_screen.dart';

class MapScreen extends StatefulWidget {
  const MapScreen({super.key});

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  int _selectedIndex = 0;
  late String _language = ApiService.currentLanguage;
  
  final MapController _mapController = MapController();
  final TextEditingController _searchController = TextEditingController();

  void _toggleLanguage() {
    setState(() {
      _language = _language == 'en' ? 'ar' : 'en';
      ApiService.currentLanguage = _language;
    });
  }

  final LatLng _ammanCenter = const LatLng(31.9539, 35.9106);

  List<Hazard> _hazards = [];
  bool _isLoading = true;

  LatLng? _myCurrentLocation;
  StreamSubscription<Position>? _positionStream;

  // --- GOOGLE MAPS STYLE FILTER STATE ---
  String _selectedMapStyle = 'default'; 
  
  bool _showHeatmap = true;
  bool _showPotholes = true;
  bool _showCracks = true;
  bool _showFadedLines = true;
  bool _showBrokenManholes = true;
  bool _showHighSeverity = true;
  bool _showMediumSeverity = true;
  bool _showLowSeverity = true;

  @override
  void initState() {
    super.initState();
    _fetchLiveHazards();
    _initLiveLocationTracking();
  }

  @override
  void dispose() {
    _positionStream?.cancel();
    _mapController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _fetchLiveHazards() async {
    final liveData = await ApiService.fetchHazards();
    setState(() {
      _hazards = liveData;
      _isLoading = false;
    });
  }

  Future<void> _initLiveLocationTracking() async {
    bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) return;

    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) return;
    }
    if (permission == LocationPermission.deniedForever) return;

    Position initialPosition = await Geolocator.getCurrentPosition(desiredAccuracy: LocationAccuracy.high);
    if (mounted) {
      setState(() {
        _myCurrentLocation = LatLng(initialPosition.latitude, initialPosition.longitude);
      });
    }

    _positionStream = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(accuracy: LocationAccuracy.high, distanceFilter: 2),
    ).listen((Position position) {
      if (mounted) {
        setState(() {
          _myCurrentLocation = LatLng(position.latitude, position.longitude);
        });
      }
    });
  }

  Future<void> _snapToCurrentLocation() async {
    final isArabic = _language == 'ar';
    
    bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(isArabic ? 'يرجى تفعيل خدمات الموقع' : 'Please enable location services'), behavior: SnackBarBehavior.floating));
      return;
    }

    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) return;
    }

    if (_myCurrentLocation != null) {
      _mapController.move(_myCurrentLocation!, 16.0);
    } else {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(isArabic ? 'جاري تحديد موقعك...' : 'Getting current location...'), behavior: SnackBarBehavior.floating, duration: const Duration(seconds: 1)));
      Position position = await Geolocator.getCurrentPosition(desiredAccuracy: LocationAccuracy.high);
      if (!mounted) return;
      setState(() => _myCurrentLocation = LatLng(position.latitude, position.longitude));
      _mapController.move(_myCurrentLocation!, 16.0);
    }
  }

  // ==========================================
  // THE NEW DETECTION MODE MENU (OPTION 2)
  // ==========================================
  void _showDetectionModeDialog() {
    final isArabic = _language == 'ar';

    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1E1E1E),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) {
        return Directionality(
          textDirection: isArabic ? TextDirection.rtl : TextDirection.ltr,
          child: Padding(
            padding: const EdgeInsets.all(24.0),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Container(
                    width: 40, height: 4, 
                    decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(2))
                  )
                ),
                const SizedBox(height: 20),
                Text(
                  isArabic ? 'طريقة الرصد' : 'Detection Mode', 
                  style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.bold)
                ),
                const SizedBox(height: 8),
                Text(
                  isArabic ? 'كيف تود الإبلاغ عن الضرر؟' : 'How would you like to report the hazard?', 
                  style: const TextStyle(color: Colors.white54, fontSize: 14)
                ),
                const SizedBox(height: 24),

                // Option A: Live AI Camera
                InkWell(
                  // 🚨 FIX: Made async to wait and reload
                  onTap: () async {
                    Navigator.pop(context); // Close the bottom sheet first
                    await Navigator.push(context, MaterialPageRoute(builder: (context) => const LiveCameraScreen()));
                    _fetchLiveHazards(); // 🚨 FIX: Reloads map data instantly upon returning
                  },
                  borderRadius: BorderRadius.circular(16),
                  child: Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: const Color(0xFFFFD700).withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: const Color(0xFFFFD700), width: 1.5),
                    ),
                    child: Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: const BoxDecoration(color: Color(0xFFFFD700), shape: BoxShape.circle),
                          child: const Icon(Icons.smart_toy, color: Colors.black, size: 28),
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(isArabic ? 'الكاميرا الذكية (مباشر)' : 'Live AI Dashcam', style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
                              const SizedBox(height: 4),
                              Text(isArabic ? 'تثبيت الهاتف في السيارة للرصد التلقائي' : 'Mount phone in car for auto-detection', style: const TextStyle(color: Colors.white54, fontSize: 12)),
                            ],
                          ),
                        ),
                        const Icon(Icons.chevron_right, color: Color(0xFFFFD700)),
                      ],
                    ),
                  ),
                ),

                const SizedBox(height: 16),

                // Option B: Manual Photo
                InkWell(
                  // 🚨 FIX: Made async to wait and reload
                  onTap: () async {
                    Navigator.pop(context); // Close the bottom sheet first
                    await Navigator.push(context, MaterialPageRoute(builder: (context) => const ReportDamageScreen()));
                    _fetchLiveHazards(); // 🚨 FIX: Reloads map data instantly upon returning
                  },
                  borderRadius: BorderRadius.circular(16),
                  child: Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.05),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: Colors.white24, width: 1),
                    ),
                    child: Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.1), shape: BoxShape.circle),
                          child: const Icon(Icons.camera_alt, color: Colors.white, size: 28),
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(isArabic ? 'إبلاغ يدوي' : 'Manual Photo Report', style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
                              const SizedBox(height: 4),
                              Text(isArabic ? 'التقاط صورة للضرر بشكل يدوي' : 'Snap a picture of the hazard manually', style: const TextStyle(color: Colors.white54, fontSize: 12)),
                            ],
                          ),
                        ),
                        const Icon(Icons.chevron_right, color: Colors.white54),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 30),
              ],
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final isArabic = _language == 'ar';

    List<Hazard> filteredHazards = _hazards.where((h) {
      if (h.typeId == 1 && !_showPotholes) return false;
      if (h.typeId == 2 && !_showCracks) return false;
      if (h.typeId == 3 && !_showFadedLines) return false;
      if (h.typeId == 4 && !_showBrokenManholes) return false; 

      bool isHigh = h.detectionCount > 10;
      bool isMedium = h.detectionCount > 3 && h.detectionCount <= 10;
      bool isLow = h.detectionCount <= 3;

      if (isHigh && !_showHighSeverity) return false;
      if (isMedium && !_showMediumSeverity) return false;
      if (isLow && !_showLowSeverity) return false;

      return true;
    }).toList();

    List<WeightedLatLng> heatmapPoints = filteredHazards.map((h) => WeightedLatLng(h.location, 1.0)).toList();

    String currentTileUrl = 'https://mt1.google.com/vt/lyrs=m&x={x}&y={y}&z={z}'; 
    if (_selectedMapStyle == 'satellite') {
      currentTileUrl = 'https://mt1.google.com/vt/lyrs=y&x={x}&y={y}&z={z}'; 
    } else if (_selectedMapStyle == 'terrain') {
      currentTileUrl = 'https://mt1.google.com/vt/lyrs=p&x={x}&y={y}&z={z}'; 
    }

    return Directionality(
      textDirection: isArabic ? TextDirection.rtl : TextDirection.ltr,
      child: Scaffold(
        backgroundColor: const Color(0xFF121212),
        extendBody: true,
        resizeToAvoidBottomInset: false, 
        
        floatingActionButtonLocation: FloatingActionButtonLocation.centerDocked,
        floatingActionButton: Transform.translate(
          offset: const Offset(0, 20),
          child: SizedBox(
            height: 80, width: 80,
            child: FloatingActionButton(
              heroTag: "detect_fab",
              // --- Opens the choice menu! ---
              onPressed: _showDetectionModeDialog,
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
                  mapController: _mapController, 
                  options: MapOptions(initialCenter: _ammanCenter, initialZoom: 14.0, minZoom: 5.0, maxZoom: 18.0),
                  children: [
                    TileLayer(urlTemplate: currentTileUrl),
                    
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

                    if (_myCurrentLocation != null)
                      MarkerLayer(
                        markers: [
                          Marker(
                            point: _myCurrentLocation!,
                            width: 60,
                            height: 60,
                            child: Stack(
                              alignment: Alignment.center,
                              children: [
                                Container(width: 60, height: 60, decoration: BoxDecoration(color: Colors.blue.withValues(alpha: 0.25), shape: BoxShape.circle)),
                                Container(width: 22, height: 22, decoration: BoxDecoration(color: Colors.blue[600], shape: BoxShape.circle, border: Border.all(color: Colors.white, width: 3), boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.3), blurRadius: 4, spreadRadius: 1)])),
                              ],
                            ),
                          ),
                        ],
                      ),
                  ],
                ),
                
                _buildSearchBar(isArabic),
                _buildMyLocationButton(),

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

  // ==========================================
  // GOOGLE MAPS UI COMPONENTS
  // ==========================================

  Widget _buildSearchBar(bool isArabic) {
    return Positioned(
      top: 50, left: 16, right: 16,
      child: Container(
        decoration: BoxDecoration(
          color: const Color(0xFF1E1E1E), 
          borderRadius: BorderRadius.circular(30),
          boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.5), blurRadius: 10, offset: const Offset(0, 4))],
        ),
        child: TextField(
          controller: _searchController,
          style: const TextStyle(color: Colors.white),
          decoration: InputDecoration(
            hintText: isArabic ? 'البحث في راصد...' : 'Search in Rased...',
            hintStyle: const TextStyle(color: Colors.white54),
            prefixIcon: const Icon(Icons.search, color: Colors.white54),
            suffixIcon: IconButton(
              icon: const Icon(Icons.layers, color: Color(0xFFFFD700)),
              onPressed: _showFilterMenu,
            ),
            border: InputBorder.none,
            contentPadding: const EdgeInsets.symmetric(vertical: 15),
          ),
          onSubmitted: (value) async {
            if (value.trim().isEmpty) return;
            try {
              List<Location> locations = await locationFromAddress(value);
              if (locations.isNotEmpty) {
                final loc = locations.first;
                _mapController.move(LatLng(loc.latitude, loc.longitude), 15.0);
              }
            } catch (e) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text(isArabic ? 'لم يتم العثور على الموقع' : 'Location not found'), backgroundColor: Colors.red, behavior: SnackBarBehavior.floating),
              );
            }
          },
        ),
      ),
    );
  }

  Widget _buildMyLocationButton() {
    return Positioned(
      bottom: 150, 
      right: 16,
      child: FloatingActionButton(
        heroTag: "my_location_btn",
        mini: true, 
        backgroundColor: const Color(0xFF1E1E1E),
        child: const Icon(Icons.my_location, color: Color(0xFFFFD700)),
        onPressed: _snapToCurrentLocation,
      ),
    );
  }

  // ==========================================
  // GOOGLE MAPS STYLE FILTER MENU
  // ==========================================
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
              child: SingleChildScrollView( 
                child: Padding(
                  padding: EdgeInsets.only(
                    bottom: MediaQuery.of(context).viewInsets.bottom + 24.0,
                    top: 16.0, left: 24.0, right: 24.0
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Center(child: Container(width: 40, height: 4, decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(2)))),
                      const SizedBox(height: 16),
                      
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(isArabic ? 'نوع الخريطة' : 'Map type', style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
                          IconButton(icon: const Icon(Icons.close, color: Colors.white54), onPressed: () => Navigator.pop(context)),
                        ],
                      ),
                      const SizedBox(height: 16),
                      
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceAround,
                        children: [
                          _buildMapTypeCard(isArabic ? 'تلقائي' : 'Default', 'default', Icons.map, setModalState),
                          _buildMapTypeCard(isArabic ? 'قمر صناعي' : 'Satellite', 'satellite', Icons.satellite_alt, setModalState),
                          _buildMapTypeCard(isArabic ? 'تضاريس' : 'Terrain', 'terrain', Icons.terrain, setModalState),
                        ],
                      ),
                      
                      const SizedBox(height: 24),
                      const Divider(color: Colors.white24),
                      const SizedBox(height: 16),

                      Text(isArabic ? 'تفاصيل الخريطة' : 'Map details', style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
                      const SizedBox(height: 16),
                      
                      Wrap(
                        spacing: 16,
                        runSpacing: 20,
                        alignment: WrapAlignment.start,
                        children: [
                          _buildDetailCard(isArabic ? 'حرارية' : 'Heatmap', _showHeatmap, () { setModalState(() => _showHeatmap = !_showHeatmap); setState((){}); }, '🔥'),
                          _buildDetailCard(isArabic ? 'حفر ($potholeCount)' : 'Potholes', _showPotholes, () { setModalState(() => _showPotholes = !_showPotholes); setState((){}); }, '🕳️'),
                          _buildDetailCard(isArabic ? 'تشقق ($crackCount)' : 'Cracks', _showCracks, () { setModalState(() => _showCracks = !_showCracks); setState((){}); }, '⚡'),
                          _buildDetailCard(isArabic ? 'باهتة ($fadedLinesCount)' : 'Faded', _showFadedLines, () { setModalState(() => _showFadedLines = !_showFadedLines); setState((){}); }, '〰️'),
                          _buildDetailCard(isArabic ? 'مناهل ($manholeCount)' : 'Manholes', _showBrokenManholes, () { setModalState(() => _showBrokenManholes = !_showBrokenManholes); setState((){}); }, '🚧'),
                          
                          _buildDetailCard(isArabic ? 'عالية' : 'High', _showHighSeverity, () { setModalState(() => _showHighSeverity = !_showHighSeverity); setState((){}); }, '🔴'),
                          _buildDetailCard(isArabic ? 'متوسطة' : 'Medium', _showMediumSeverity, () { setModalState(() => _showMediumSeverity = !_showMediumSeverity); setState((){}); }, '🟡'),
                          _buildDetailCard(isArabic ? 'منخفضة' : 'Low', _showLowSeverity, () { setModalState(() => _showLowSeverity = !_showLowSeverity); setState((){}); }, '🟢'),
                        ],
                      ),
                      const SizedBox(height: 30),
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

  Widget _buildMapTypeCard(String title, String value, IconData icon, StateSetter setModalState) {
    bool isSelected = _selectedMapStyle == value;
    return GestureDetector(
      onTap: () {
        setModalState(() => _selectedMapStyle = value);
        setState(() {}); 
      },
      child: Column(
        children: [
          Container(
            width: 70, height: 70,
            decoration: BoxDecoration(
              color: const Color(0xFF2C2C2C),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: isSelected ? Colors.blue : Colors.transparent, width: 2),
            ),
            child: Icon(icon, color: isSelected ? Colors.blue : Colors.white, size: 30),
          ),
          const SizedBox(height: 8),
          Text(title, style: TextStyle(color: isSelected ? Colors.blue : Colors.white70, fontSize: 13, fontWeight: isSelected ? FontWeight.bold : FontWeight.normal)),
        ],
      ),
    );
  }

  Widget _buildDetailCard(String title, bool isSelected, VoidCallback onTap, String emoji) {
    return GestureDetector(
      onTap: onTap,
      child: SizedBox(
        width: 75,
        child: Column(
          children: [
            Container(
              width: 60, height: 60,
              decoration: BoxDecoration(
                color: isSelected ? Colors.blue.withValues(alpha: 0.15) : const Color(0xFF2C2C2C),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: isSelected ? Colors.blue : Colors.transparent, width: 2),
              ),
              child: Center(child: Text(emoji, style: const TextStyle(fontSize: 24))),
            ),
            const SizedBox(height: 8),
            Text(title, textAlign: TextAlign.center, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: isSelected ? Colors.blue : Colors.white70, fontSize: 12, fontWeight: isSelected ? FontWeight.bold : FontWeight.normal)),
          ],
        ),
      ),
    );
  }

  // ==========================================
  // MAP DATA HELPER WIDGETS
  // ==========================================

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
              }).catchError((e) { debugPrint("Could not translate location."); });
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