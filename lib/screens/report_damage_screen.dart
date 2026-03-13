import 'dart:ui';
import 'package:flutter/material.dart';

class ReportDamageScreen extends StatefulWidget {
  const ReportDamageScreen({super.key});

  @override
  State<ReportDamageScreen> createState() => _ReportDamageScreenState();
}

class _ReportDamageScreenState extends State<ReportDamageScreen> {
  String _selectedDamageType = 'Pothole (ثقبة طريق)';
  final TextEditingController _descriptionController = TextEditingController();

  final List<String> _damageTypes = [
    'Pothole (ثقبة طريق)',
    'Crack (تشقق)',
    'Faded Lines (خطوط باهتة)',
    'Other (أخرى)'
  ];

  @override
  void dispose() {
    _descriptionController.dispose();
    super.dispose();
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
          'تأكيد الرصد (Confirm Report)',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 20),
        ),
        centerTitle: true,
      ),
      body: SingleChildScrollView(
        physics: const BouncingScrollPhysics(),
        padding: const EdgeInsets.all(20.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildImagePreview(),
            const SizedBox(height: 24),
            _buildSectionTitle('الموقع (Location)'),
            const SizedBox(height: 8),
            _buildGlassContainer(
              child: Row(
                children: const [
                  Icon(Icons.location_on, color: Color(0xFFFFD700)),
                  SizedBox(width: 10),
                  Text('Amman, Queen Rania St.', style: TextStyle(color: Colors.white70, fontSize: 16)),
                ],
              ),
            ),
            const SizedBox(height: 24),
            _buildSectionTitle('نوع الضرر (Damage Type)'),
            const SizedBox(height: 8),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: _damageTypes.map((type) {
                final isSelected = _selectedDamageType == type;
                return ChoiceChip(
                  label: Text(type),
                  selected: isSelected,
                  onSelected: (selected) {
                    if (selected) {
                      setState(() => _selectedDamageType = type);
                    }
                  },
                  selectedColor: const Color(0xFFFFD700),
                  backgroundColor: Colors.white.withValues(alpha: 0.1),
                  labelStyle: TextStyle(
                    color: isSelected ? const Color(0xFF121212) : Colors.white70,
                    fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                  ),
                  side: BorderSide(
                    color: isSelected ? const Color(0xFFFFD700) : Colors.white.withValues(alpha: 0.2),
                  ),
                );
              }).toList(),
            ),
            const SizedBox(height: 24),
            _buildSectionTitle('تفاصيل إضافية (Description)'),
            const SizedBox(height: 8),
            _buildGlassContainer(
              child: TextField(
                controller: _descriptionController,
                maxLines: 4,
                style: const TextStyle(color: Colors.white),
                decoration: const InputDecoration(
                  hintText: 'Add any extra details here...',
                  hintStyle: TextStyle(color: Colors.white30),
                  border: InputBorder.none,
                ),
              ),
            ),
            const SizedBox(height: 40),
            SizedBox(
              width: double.infinity,
              height: 55,
              child: ElevatedButton(
                onPressed: () {
                  debugPrint("Report Submitted: $_selectedDamageType");
                  Navigator.pop(context);
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFFFFD700),
                  foregroundColor: const Color(0xFF121212),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
                  elevation: 5,
                  shadowColor: const Color(0xFFFFD700).withValues(alpha: 0.5),
                ),
                child: const Text(
                  'إرسال التقرير (Submit Report)',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
              ),
            ),
            const SizedBox(height: 20),
          ],
        ),
      ),
    );
  }

  Widget _buildSectionTitle(String title) {
    return Text(
      title,
      style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
    );
  }

  Widget _buildImagePreview() {
    return ClipRRect(
      borderRadius: BorderRadius.circular(20),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
        child: Container(
          height: 200,
          width: double.infinity,
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.05),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: Colors.white.withValues(alpha: 0.15)),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.camera_alt_outlined, size: 50, color: Colors.white.withValues(alpha: 0.5)),
              const SizedBox(height: 10),
              Text(
                'AI Analysis Complete\nConfidence: 94%',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white.withValues(alpha: 0.7), fontSize: 14),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildGlassContainer({required Widget child}) {
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
          child: child,
        ),
      ),
    );
  }
}