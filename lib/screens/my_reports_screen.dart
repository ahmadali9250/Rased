import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:geocoding/geocoding.dart';
import '../services/api_service.dart';

class MyReportsScreen extends StatefulWidget {
  const MyReportsScreen({super.key});

  @override
  State<MyReportsScreen> createState() => _MyReportsScreenState();
}

class _MyReportsScreenState extends State<MyReportsScreen> {
  List<Hazard> _myReports = []; 
  bool _isLoading = true; 

  @override
  void initState() {
    super.initState();
    _fetchMyReports(); 
  }

  Future<void> _fetchMyReports() async {
    final liveData = await ApiService.fetchHazards();
    
    if (mounted) {
      setState(() {
        _myReports = liveData;
        _isLoading = false;
      });
    }
  }

  // --- Translates GPS to Street Names ---
  Future<String> _getAddress(double lat, double lng) async {
    try {
      // Ask the internet what street this is!
      List<Placemark> placemarks = await placemarkFromCoordinates(lat, lng);
      if (placemarks.isNotEmpty) {
        Placemark place = placemarks.first;
        // Combines the street name and the city (e.g., "Mecca St, Amman")
        return "${place.street}, ${place.locality}";
      }
    } catch (e) {
      debugPrint("Could not find address: $e");
    }
    // If it fails, just return the raw numbers as a backup
    return "${lat.toStringAsFixed(4)}, ${lng.toStringAsFixed(4)}";
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF121212), 
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
      
      body: _isLoading 
        ? const Center(child: CircularProgressIndicator(color: Color(0xFFFFD700)))
        : _myReports.isEmpty 
          ? const Center(child: Text("No reports yet!", style: TextStyle(color: Colors.white54)))
          : ListView.builder(
              physics: const BouncingScrollPhysics(),
              padding: const EdgeInsets.only(top: 20, left: 20, right: 20, bottom: 120),
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

  Widget _buildReportCard(Hazard report) {
    final bool isResolved = report.statusId == 2; 
    final String typeName = report.typeId == 1 ? "Pothole" : "Hazard Type ${report.typeId}";

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
                      color: isResolved ? Colors.green.withValues(alpha: 0.2) : const Color(0xFFFFD700).withValues(alpha: 0.2),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: isResolved ? Colors.green : const Color(0xFFFFD700)),
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
              
              // --- The FutureBuilder for Location ---
              Row(
                children: [
                  const Icon(Icons.location_on, color: Colors.white54, size: 16),
                  const SizedBox(width: 8),
                  Expanded(
                    child: FutureBuilder<String>(
                      future: _getAddress(report.location.latitude, report.location.longitude),
                      builder: (context, snapshot) {
                        // While waiting for the internet...
                        if (snapshot.connectionState == ConnectionState.waiting) {
                          return const Text(
                            "Translating GPS...", 
                            style: TextStyle(color: Colors.white54, fontSize: 14, fontStyle: FontStyle.italic)
                          );
                        }
                        // Once we have the street name!
                        return Text(
                          snapshot.data ?? "Location Unknown",
                          style: const TextStyle(color: Colors.white70, fontSize: 14),
                          overflow: TextOverflow.ellipsis, // Adds ... if the street name is too long!
                        );
                      },
                    ),
                  ),
                ],
              ),
              
              const SizedBox(height: 8),
              const Row(
                children: [
                  Icon(Icons.calendar_today, color: Colors.white54, size: 16),
                  SizedBox(width: 8),
                  Text("Reported Today", style: TextStyle(color: Colors.white70, fontSize: 14)),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}