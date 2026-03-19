import 'dart:ui';
import 'package:flutter/material.dart';
import '../services/api_service.dart';

class MyReportsScreen extends StatefulWidget {
  const MyReportsScreen({super.key});

  @override
  State<MyReportsScreen> createState() => _MyReportsScreenState();
}

class _MyReportsScreenState extends State<MyReportsScreen> {
  List<Hazard> _myReports = []; // Holds the real data
  bool _isLoading = true; // Shows the spinner while loading

  @override
  void initState() {
    super.initState();
    _fetchMyReports(); // Fetch data the moment the screen opens
  }

  Future<void> _fetchMyReports() async {
    // For now, we are just fetching all hazards. 
    // Later, your friend can add a /Hazards/my endpoint!
    final liveData = await ApiService.fetchHazards();
    
    if (mounted) {
      setState(() {
        _myReports = liveData;
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF121212), // Deep dark background
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        iconTheme: const IconThemeData(color: Colors.white),
        title: const Text(
          'My Reports',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 20),
        ),
        centerTitle: true,
      ),
      
      // If loading, show spinner. Otherwise, show the list!
      body: _isLoading 
        ? const Center(child: CircularProgressIndicator(color: Color(0xFFFFD700)))
        : _myReports.isEmpty 
          ? const Center(child: Text("No reports yet!", style: TextStyle(color: Colors.white54)))
          : ListView.builder(
              physics: const BouncingScrollPhysics(),
              padding: const EdgeInsets.all(20),
              itemCount: _myReports.length,
              itemBuilder: (context, index) {
                final report = _myReports[index];
                return Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: _buildReportCard(report),
                );
              },
            ),
    );
  }

  // --- Helper Widget for the Glassmorphism Card ---
  Widget _buildReportCard(Hazard report) {
    // Check status based on your friend's database (Assuming 1=Pending, 2=Resolved)
    final bool isResolved = report.statusId == 2; 
    
    // Convert your friend's TypeID to a string
    final String typeName = report.typeId == 1 ? "Pothole" : "Hazard Type ${report.typeId}";

    // Format the GPS coordinates for the card
    final String locationText = "${report.location.latitude.toStringAsFixed(4)}, ${report.location.longitude.toStringAsFixed(4)}";

    return ClipRRect(
      borderRadius: BorderRadius.circular(15),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.05),
            borderRadius: BorderRadius.circular(15),
            border: Border.all(color: Colors.white.withValues(alpha: 0.15)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Top Row: Type and Status Badge
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    typeName,
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: isResolved
                          ? Colors.green.withValues(alpha: 0.2)
                          : const Color(0xFFFFD700).withValues(alpha: 0.2),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(
                        color: isResolved ? Colors.green : const Color(0xFFFFD700),
                      ),
                    ),
                    child: Text(
                      isResolved ? 'Resolved' : 'Pending',
                      style: TextStyle(
                        color: isResolved ? Colors.greenAccent : const Color(0xFFFFD700),
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              
              // Location Row (Now shows real GPS coordinates!)
              Row(
                children: [
                  const Icon(Icons.location_on, color: Colors.white54, size: 16),
                  const SizedBox(width: 8),
                  Text(
                    locationText,
                    style: const TextStyle(color: Colors.white70, fontSize: 14),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              
              // Date Row (We'll just put "Today" for now since the API didn't have a date field in the screenshot)
              const Row(
                children: [
                  Icon(Icons.calendar_today, color: Colors.white54, size: 16),
                  SizedBox(width: 8),
                  Text(
                    "Reported Today",
                    style: TextStyle(color: Colors.white70, fontSize: 14),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}