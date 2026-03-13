import 'dart:ui';
import 'package:flutter/material.dart';

class MyReportsScreen extends StatelessWidget {
  const MyReportsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    // Mock data representing the user's past reports
    final List<Map<String, dynamic>> reports = [
      {
        'type': 'Pothole (ثقبة طريق)',
        'location': 'Amman, Queen Rania St.',
        'date': '2026-03-12',
        'status': 'قيد المراجعة (Pending)',
        'isResolved': false,
      },
      {
        'type': 'Faded Lines (خطوط باهتة)',
        'location': 'Amman, Mecca St.',
        'date': '2026-03-05',
        'status': 'تم الحل (Resolved)',
        'isResolved': true,
      },
      {
        'type': 'Crack (تشقق)',
        'location': 'Amman, Abdullah Ghosheh St.',
        'date': '2026-02-28',
        'status': 'تم الحل (Resolved)',
        'isResolved': true,
      },
    ];

    return Scaffold(
      backgroundColor: const Color(0xFF121212), // Deep dark background
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        iconTheme: const IconThemeData(color: Colors.white),
        title: const Text(
          'بلاغاتي (My Reports)',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 20),
        ),
        centerTitle: true,
      ),
      body: ListView.builder(
        physics: const BouncingScrollPhysics(),
        padding: const EdgeInsets.all(20),
        itemCount: reports.length,
        itemBuilder: (context, index) {
          final report = reports[index];
          return Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: _buildReportCard(report),
          );
        },
      ),
    );
  }

  // --- Helper Widget for the Glassmorphism Card ---
  Widget _buildReportCard(Map<String, dynamic> report) {
    final bool isResolved = report['isResolved'];

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
                    report['type'],
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
                      report['status'],
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
              
              // Location Row
              Row(
                children: [
                  const Icon(Icons.location_on, color: Colors.white54, size: 16),
                  const SizedBox(width: 8),
                  Text(
                    report['location'],
                    style: const TextStyle(color: Colors.white70, fontSize: 14),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              
              // Date Row
              Row(
                children: [
                  const Icon(Icons.calendar_today, color: Colors.white54, size: 16),
                  const SizedBox(width: 8),
                  Text(
                    report['date'],
                    style: const TextStyle(color: Colors.white70, fontSize: 14),
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