import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:geocoding/geocoding.dart';
import '../services/api_service.dart';
import '../services/app_language.dart';
import '../services/report_events.dart';
import '../utils/formatters.dart';
import '../utils/hazard_labels.dart';

/// Displays a historical list of hazards specifically reported by the logged-in user.
///
/// Refreshes on: pull-down, the refresh button, the tab becoming visible,
/// a language change, and every [ReportEvents] bump (a report was sent or an
/// admin changed a status), so a new report shows up without re-login.
class MyReportsScreen extends StatefulWidget {
  final String language;

  /// True while this tab is the visible one. Turning true refetches.
  final bool isActive;

  const MyReportsScreen({
    super.key,
    required this.language,
    this.isActive = true,
  });

  @override
  State<MyReportsScreen> createState() => _MyReportsScreenState();
}

class _MyReportsScreenState extends State<MyReportsScreen> {
  List<Hazard> _myReports = [];
  bool _isLoading = true;
  late String _language = widget.language;

  Future<void>? _inFlight;
  bool _refetchQueued = false;

  @override
  void initState() {
    super.initState();
    ReportEvents.version.addListener(_onReportsChanged);
    _fetchMyReports();
  }

  @override
  void dispose() {
    ReportEvents.version.removeListener(_onReportsChanged);
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant MyReportsScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.language != widget.language) {
      _language = widget.language;
      _fetchMyReports();
    } else if (!oldWidget.isActive && widget.isActive) {
      _fetchMyReports();
    }
  }

  void _onReportsChanged() => _fetchMyReports();

  /// One request at a time; a call during a fetch schedules one more after
  /// it, so the newest server state always lands.
  Future<void> _fetchMyReports() {
    final running = _inFlight;
    if (running != null) {
      _refetchQueued = true;
      return running;
    }
    final future = _load().whenComplete(() {
      _inFlight = null;
      if (_refetchQueued) {
        _refetchQueued = false;
        _fetchMyReports();
      }
    });
    _inFlight = future;
    return future;
  }

  Future<void> _load() async {
    final myData = await ApiService.fetchMyReports(language: _language);
    if (!mounted) return;
    setState(() {
      _myReports = myData;
      _isLoading = false;
    });
  }

  // --- Translates GPS to Street Names ---
  Future<String> _getAddress(double lat, double lng) async {
    try {
      List<Placemark> placemarks = await placemarkFromCoordinates(lat, lng);
      if (placemarks.isNotEmpty) {
        final text = formatPlacemark(placemarks.first);
        if (text.isNotEmpty) return text;
      }
    } catch (e) {
      debugPrint("Could not find address: $e");
    }
    return "${lat.toStringAsFixed(4)}, ${lng.toStringAsFixed(4)}";
  }

  @override
  Widget build(BuildContext context) {
    final isArabic = context.isArabic;

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
          actions: [
            IconButton(
              icon: const Icon(Icons.refresh),
              tooltip: isArabic ? 'تحديث' : 'Refresh',
              onPressed: _fetchMyReports,
            ),
          ],
        ),
        body: RefreshIndicator(
          color: const Color(0xFFFFD700),
          backgroundColor: const Color(0xFF1E1E1E),
          onRefresh: _fetchMyReports,
          child: _isLoading
              ? const Center(child: CircularProgressIndicator(color: Color(0xFFFFD700)))
              : _myReports.isEmpty
                  ? _buildEmptyState(isArabic)
                  : ListView.builder(
                      physics: const AlwaysScrollableScrollPhysics(parent: BouncingScrollPhysics()),
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
      ),
    );
  }

  /// Scrollable even when empty, so pull-to-refresh still works.
  Widget _buildEmptyState(bool isArabic) {
    return LayoutBuilder(
      builder: (context, constraints) => ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          SizedBox(
            height: constraints.maxHeight,
            child: Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.receipt_long, size: 80, color: Colors.white24),
                  const SizedBox(height: 16),
                  Text(
                    isArabic ? "لا توجد بلاغات حتى الآن!" : "No reports yet!",
                    style: const TextStyle(color: Colors.white54, fontSize: 18),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    isArabic ? "اسحب للأسفل للتحديث" : "Pull down to refresh",
                    style: const TextStyle(color: Colors.white38, fontSize: 13),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Builds a beautifully styled glassmorphism card for a single report.
  Widget _buildReportCard(Hazard report, bool isArabic) {
    final String typeName = HazardLabels.type(report, isArabic);
    final String statusText = HazardLabels.status(report, isArabic);
    final Color statusColor = HazardLabels.statusColor(report.statusId);

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

                    // Date Row (the API has no timestamp yet)
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
