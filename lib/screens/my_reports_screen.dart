import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:geocoding/geocoding.dart';
import '../services/api_service.dart';

/// Displays a historical list of hazards specifically reported by the logged-in user.
class MyReportsScreen extends StatefulWidget {
  const MyReportsScreen({super.key});

  @override
  State<MyReportsScreen> createState() => _MyReportsScreenState();
}

class _MyReportsScreenState extends State<MyReportsScreen> {
  List<Hazard> _myReports = [];
  bool _isLoading = true;
  late String _language = ApiService.currentLanguage;

  @override
  void initState() {
    super.initState();
    _fetchMyReports();
  }

  /// FIXED: Now explicitly calls the backend developer's new 'my-reports' endpoint!
  Future<void> _fetchMyReports() async {
    final myData = await ApiService.fetchMyReports();

    if (mounted) {
      setState(() {
        _myReports = myData; 
        _isLoading = false;
      });
    }
  }

  // --- Translates GPS to Street Names ---
  Future<String> _getAddress(double lat, double lng) async {
    try {
      List<Placemark> placemarks = await placemarkFromCoordinates(lat, lng);
      if (placemarks.isNotEmpty) {
        Placemark place = placemarks.first;
        return "${place.street}, ${place.locality}";
      }
    } catch (e) {
      debugPrint("Could not find address: $e");
    }
    return "${lat.toStringAsFixed(4)}, ${lng.toStringAsFixed(4)}";
  }

  /// Translates the Status ID from the database into a readable label.
  String _getStatusText(int statusId, bool isArabic) {
    switch (statusId) {
      case 1: return isArabic ? 'قيد المراجعة' : 'Pending';
      case 2: return isArabic ? 'قيد العمل' : 'In Progress';
      case 3: return isArabic ? 'محلول' : 'Resolved';
      case 4: return isArabic ? 'مرفوض' : 'Rejected (AI)';
      default: return isArabic ? 'غير معروف' : 'Unknown';
    }
  }

  /// Maps the Status ID to a specific color for the UI badge.
  Color _getStatusColor(int statusId) {
    switch (statusId) {
      case 1: return const Color(0xFFFFD700); // Yellow/Gold
      case 2: return Colors.blueAccent;       // Blue
      case 3: return Colors.greenAccent;      // Green
      case 4: return Colors.redAccent;        // Red
      default: return Colors.grey;
    }
  }

  /// Translates the Hazard Type ID from the database into a readable label.
  String _getHazardName(int typeId, bool isArabic) {
    switch (typeId) {
      case 1: return isArabic ? 'حفرة' : 'Pothole';
      case 2: return isArabic ? 'تشقق' : 'Crack';
      case 3: return isArabic ? 'خطوط باهتة' : 'Faded Lines';
      case 4: return isArabic ? 'مناهل مكسورة' : 'Broken Manhole';
      default: return isArabic ? 'نوع غير معروف' : 'Unknown Hazard';
    }
  }

  @override
  Widget build(BuildContext context) {
    final isArabic = _language == 'ar';

    return Directionality(
      textDirection: isArabic ? TextDirection.rtl : TextDirection.ltr,
      child: Scaffold(
        backgroundColor: const Color(0xFF121212),
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          iconTheme: const IconThemeData(color: Colors.white),
          title: Text(
            isArabic ? 'بلاغاتي' : 'My Reports',
            style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 20),
          ),
          centerTitle: true,
        ),
        body: _isLoading
            ? const Center(child: CircularProgressIndicator(color: Color(0xFFFFD700)))
            : _myReports.isEmpty
                ? Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Icon(Icons.receipt_long, size: 80, color: Colors.white24),
                        const SizedBox(height: 16),
                        Text(
                          isArabic ? "لا توجد بلاغات حتى الآن!" : "No reports yet!",
                          style: const TextStyle(color: Colors.white54, fontSize: 18),
                        ),
                      ],
                    ),
                  )
                : ListView.builder(
                    physics: const BouncingScrollPhysics(),
                    padding: const EdgeInsets.only(top: 20, left: 16, right: 16, bottom: 120), // Bottom padding prevents FAB overlap
                    itemCount: _myReports.length,
                    itemBuilder: (context, index) {
                      final report = _myReports[index];
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 16),
                        child: _buildReportCard(report, isArabic),
                      );
                    },
                  ),
      ),
    );
  }

  /// Builds a beautifully styled glassmorphism card for a single report.
  Widget _buildReportCard(Hazard report, bool isArabic) {
    final String typeName = _getHazardName(report.typeId, isArabic);
    final String statusText = _getStatusText(report.statusId, isArabic);
    final Color statusColor = _getStatusColor(report.statusId);

    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.05),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // --- 1. IMAGE THUMBNAIL ---
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Container(
                  width: 80,
                  height: 80,
                  color: Colors.black26,
                  child: report.fullImageUrl != null
                      ? Image.network(
                          report.fullImageUrl!,
                          fit: BoxFit.cover,
                          errorBuilder: (context, error, stack) => const Icon(Icons.broken_image, color: Colors.white38),
                        )
                      : const Icon(Icons.image_not_supported, color: Colors.white38),
                ),
              ),
              const SizedBox(width: 16),

              // --- 2. REPORT DETAILS ---
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Header Row: Hazard Name & Status Badge
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          typeName,
                          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16),
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                          decoration: BoxDecoration(
                            color: statusColor.withValues(alpha: 0.2),
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(color: statusColor),
                          ),
                          child: Text(
                            statusText,
                            style: TextStyle(color: statusColor, fontSize: 10, fontWeight: FontWeight.bold),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),

                    // Location Row with FutureBuilder
                    Row(
                      children: [
                        const Icon(Icons.location_on, color: Colors.white54, size: 16),
                        const SizedBox(width: 6),
                        Expanded(
                          child: FutureBuilder<String>(
                            future: _getAddress(report.location.latitude, report.location.longitude),
                            builder: (context, snapshot) {
                              if (snapshot.connectionState == ConnectionState.waiting) {
                                return Text(
                                  isArabic ? "جاري ترجمة الموقع..." : "Translating GPS...",
                                  style: const TextStyle(color: Colors.white54, fontSize: 12, fontStyle: FontStyle.italic),
                                );
                              }
                              return Text(
                                snapshot.data ?? (isArabic ? "موقع غير معروف" : "Location Unknown"),
                                style: const TextStyle(color: Colors.white70, fontSize: 12),
                                overflow: TextOverflow.ellipsis,
                              );
                            },
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),

                    // Date Row
                    Row(
                      children: [
                        const Icon(Icons.calendar_today, color: Colors.white54, size: 14),
                        const SizedBox(width: 6),
                        Text(
                          isArabic ? "تم الإبلاغ حديثاً" : "Reported recently",
                          style: const TextStyle(color: Colors.white54, fontSize: 12),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}