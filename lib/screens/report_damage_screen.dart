import 'dart:ui';
import 'package:flutter/material.dart';
import 'dart:io';
import 'package:image_picker/image_picker.dart';
import 'package:geolocator/geolocator.dart';
import 'package:geocoding/geocoding.dart';
import '../services/tflite_service.dart';
import '../services/api_service.dart';

/// The Manual Hazard Reporting Screen.
///
/// Allows users to manually capture or upload a photo of a road hazard, 
/// automatically tags it with GPS coordinates, and submits it to the backend.
/// Acts as a crucial fallback for the Live AI Camera.
class ReportDamageScreen extends StatefulWidget {
  const ReportDamageScreen({super.key});

  @override
  State<ReportDamageScreen> createState() => _ReportDamageScreenState();
}

class _ReportDamageScreenState extends State<ReportDamageScreen> {
  // --- State Variables ---
  String _selectedDamageType = 'Pothole';
  final TextEditingController _descriptionController = TextEditingController();

  final List<String> _damageTypes = [
    'Pothole',
    'Crack',
    'Faded Lines',
    'Broken Manhole',
    'Other',
  ];

  File? _selectedImage;
  final ImagePicker _picker = ImagePicker();
  final TFLiteService _tfliteService = TFLiteService(); // Local AI verification
  
  String _currentAddress = "Locating your position...";
  double? _currentLat;
  double? _currentLng;
  bool _isLoadingLocation = true;
  bool _isSubmitting = false;

  @override
  void initState() {
    super.initState();
    // Warm up the local AI model so it's ready to analyze the manual photo instantly
    _tfliteService.initializeModel();
    _getCurrentLocation();
  }

  @override
  void dispose() {
    _descriptionController.dispose();
    super.dispose();
  }

  // ==========================================
  // HARDWARE INTEGRATION: GPS
  // ==========================================
  
  /// Fetches the user's high-accuracy GPS coordinates and translates them 
  /// into a human-readable street address for the UI.
  Future<void> _getCurrentLocation() async {
    final isArabic = ApiService.currentLanguage == 'ar';
    bool serviceEnabled;
    LocationPermission permission;

    serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      setState(() {
        _currentAddress = isArabic ? 'نظام تحديد المواقع مغلق.' : 'GPS is turned off.';
        _isLoadingLocation = false;
      });
      return;
    }

    permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) {
        setState(() {
          _currentAddress = isArabic ? 'تم رفض إذن الوصول للموقع.' : 'Location permission denied.';
          _isLoadingLocation = false;
        });
        return;
      }
    }

    try {
      Position position = await Geolocator.getCurrentPosition(desiredAccuracy: LocationAccuracy.high);
      
      List<Placemark> placemarks = await placemarkFromCoordinates(position.latitude, position.longitude);
      Placemark place = placemarks[0];

      if (mounted) {
        setState(() {
          _currentAddress = "${place.street}, ${place.locality}, ${place.country}";
          _currentLat = position.latitude;
          _currentLng = position.longitude;
          _isLoadingLocation = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _currentAddress = isArabic ? 'فشل في تحديد الموقع.' : 'Failed to get location.';
          _isLoadingLocation = false;
        });
      }
    }
  }

  // ==========================================
  // HARDWARE INTEGRATION: CAMERA & GALLERY
  // ==========================================
  
  /// Opens the device camera or gallery, captures an image, and runs it 
  /// through the local TFLite model for a preliminary AI check.
  Future<void> _pickImage(ImageSource source) async {
    final XFile? pickedFile = await _picker.pickImage(
      source: source,
      imageQuality: 50, // Compress to save user data and speed up upload
      maxWidth: 800,
    );

    if (pickedFile != null) {
      setState(() {
        _selectedImage = File(pickedFile.path);
      });
      debugPrint("📸 Image selected: ${pickedFile.path}");

      // Run a quick local AI check to assist the user
      debugPrint("🤖 AI is analyzing the image...");
      String detectedDamage = await _tfliteService.predictImage(pickedFile.path);
      debugPrint("✅ AI finished! It looks like a: $detectedDamage");
      
      // Auto-select the dropdown based on AI prediction (if it matches our list)
      if (_damageTypes.contains(detectedDamage)) {
        setState(() {
          _selectedDamageType = detectedDamage;
        });
      }
    }
  }

  // ==========================================
  // UI BUILDER
  // ==========================================

  @override
  Widget build(BuildContext context) {
    final isArabic = ApiService.currentLanguage == 'ar';

    return Directionality(
      textDirection: isArabic ? TextDirection.rtl : TextDirection.ltr,
      child: Scaffold(
        backgroundColor: const Color(0xFF121212),
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          iconTheme: const IconThemeData(color: Colors.white),
          title: Text(
            isArabic ? 'تأكيد البلاغ' : 'Confirm Report',
            style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 20),
          ),
          centerTitle: true,
        ),
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // --- 1. IMAGE PREVIEW BOX ---
              GestureDetector(
                onTap: () {
                  FocusScope.of(context).unfocus();
                  _showImageSourceActionSheet(isArabic);
                },
                child: Container(
                  width: double.infinity,
                  height: 200,
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.05),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: _selectedImage == null ? Colors.white38 : const Color(0xFFFFD700),
                      width: 2,
                    ),
                  ),
                  child: _selectedImage != null
                      ? ClipRRect(
                          borderRadius: BorderRadius.circular(14),
                          child: Image.file(_selectedImage!, fit: BoxFit.cover),
                        )
                      : Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            const Icon(Icons.add_a_photo, color: Colors.white54, size: 50),
                            const SizedBox(height: 12),
                            Text(
                              isArabic ? 'اضغط لإضافة صورة للضرر' : 'Tap to add photo of the damage',
                              style: const TextStyle(color: Colors.white54, fontSize: 16),
                            ),
                          ],
                        ),
                ),
              ),

              const SizedBox(height: 30),

              // --- 2. LOCATION BAR ---
              _buildSectionTitle(isArabic ? 'الموقع' : 'Location'),
              const SizedBox(height: 12),
              _buildGlassContainer(
                child: Row(
                  children: [
                    const Icon(Icons.location_on, color: Color(0xFFFFD700)),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        _currentAddress,
                        style: const TextStyle(color: Colors.white70),
                      ),
                    ),
                    if (_isLoadingLocation)
                      const SizedBox(
                        width: 16, height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFFFFD700)),
                      )
                  ],
                ),
              ),

              const SizedBox(height: 30),

              // --- 3. DAMAGE DETAILS ---
              _buildSectionTitle(isArabic ? 'التفاصيل' : 'Details'),
              const SizedBox(height: 12),
              Text(
                isArabic ? 'نوع الضرر' : 'Type of Damage',
                style: const TextStyle(color: Colors.white70, fontSize: 14),
              ),
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.05),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.white12),
                ),
                child: DropdownButtonHideUnderline(
                  child: DropdownButton<String>(
                    value: _selectedDamageType,
                    isExpanded: true,
                    dropdownColor: const Color(0xFF1E1E1E),
                    icon: const Icon(Icons.arrow_drop_down, color: Color(0xFFFFD700)),
                    style: const TextStyle(color: Colors.white, fontSize: 16),
                    items: _damageTypes.map((String type) {
                      return DropdownMenuItem<String>(
                        value: type,
                        child: Text(_translateDamageType(type, isArabic)),
                      );
                    }).toList(),
                    onChanged: (String? newValue) {
                      if (newValue != null) {
                        setState(() {
                          _selectedDamageType = newValue;
                        });
                      }
                    },
                  ),
                ),
              ),

              const SizedBox(height: 40),

              // --- 4. SUBMIT BUTTON ---
              SizedBox(
                width: double.infinity,
                height: 55,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFFFFD700),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  onPressed: _isSubmitting ? null : () => _submitReportToBackend(isArabic),
                  child: _isSubmitting 
                      ? const SizedBox(
                          height: 24, width: 24, 
                          child: CircularProgressIndicator(color: Colors.black, strokeWidth: 3)
                        )
                      : Text(
                          isArabic ? 'إرسال البلاغ' : 'Submit Report',
                          style: const TextStyle(color: Colors.black, fontSize: 18, fontWeight: FontWeight.bold),
                        ),
                ),
              ),
              const SizedBox(height: 40),
            ],
          ),
        ),
      ),
    );
  }

  // ==========================================
  // HELPER METHODS
  // ==========================================

  void _showImageSourceActionSheet(bool isArabic) {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1E1E1E),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) => Directionality(
        textDirection: isArabic ? TextDirection.rtl : TextDirection.ltr,
        child: SafeArea(
          child: Wrap(
            children: [
              ListTile(
                leading: const Icon(Icons.camera_alt, color: Color(0xFFFFD700)),
                title: Text(isArabic ? 'التقاط صورة' : 'Take a Photo', style: const TextStyle(color: Colors.white)),
                onTap: () {
                  Navigator.of(context).pop();
                  _pickImage(ImageSource.camera);
                },
              ),
              ListTile(
                leading: const Icon(Icons.photo_library, color: Color(0xFFFFD700)),
                title: Text(isArabic ? 'اختيار من المعرض' : 'Choose from Gallery', style: const TextStyle(color: Colors.white)),
                onTap: () {
                  Navigator.of(context).pop();
                  _pickImage(ImageSource.gallery);
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _submitReportToBackend(bool isArabic) async {
    // 1. Validation Checks
    if (_selectedImage == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(isArabic ? 'الرجاء إضافة صورة للضرر أولاً!' : 'Please add a photo of the damage first!'),
          backgroundColor: Colors.red,
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }

    if (_currentLat == null || _currentLng == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(isArabic ? 'جاري تحديد موقعك، يرجى الانتظار...' : 'Still getting your location, please wait a second!'),
          backgroundColor: Colors.orange,
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }

    // 2. Start Submission
    setState(() => _isSubmitting = true);

    try {
      debugPrint("🚀 Sending report for $_selectedDamageType at $_currentAddress");
      
      bool success = await ApiService.submitReport(
        photo: XFile(_selectedImage!.path), 
        latitude: _currentLat!,
        longitude: _currentLng!,
        typeId: _getDamageTypeId(_selectedDamageType),
      );

      if (!mounted) return;

      // 3. Handle Result
      if (success) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(isArabic ? '✅ تم إرسال البلاغ بنجاح!' : '✅ Report submitted successfully!'),
            backgroundColor: Colors.green,
            behavior: SnackBarBehavior.floating,
          ),
        );
        Navigator.pop(context); // Close screen, return to map
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(isArabic ? '❌ فشل الإرسال إلى الخادم.' : '❌ Failed to upload to the server.'),
            backgroundColor: Colors.red,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red, behavior: SnackBarBehavior.floating),
      );
    } finally {
      if (mounted) setState(() => _isSubmitting = false);
    }
  }

  Widget _buildSectionTitle(String title) {
    return Text(
      title,
      style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
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

  String _translateDamageType(String type, bool isArabic) {
    if (!isArabic) return type;
    switch (type) {
      case 'Pothole': return 'حفرة';
      case 'Crack': return 'تشقق';
      case 'Faded Lines': return 'خطوط باهتة';
      case 'Broken Manhole': return 'مناهل مكسورة';
      default: return 'أخرى';
    }
  }

  int _getDamageTypeId(String type) {
    switch (type) {
      case 'Pothole': return 1;
      case 'Crack': return 2;
      case 'Faded Lines': return 3;
      case 'Broken Manhole': return 4;
      default: return 5;
    }
  }
}