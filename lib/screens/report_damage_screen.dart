import 'dart:ui';
import 'package:flutter/material.dart';
import 'dart:io';
import 'package:image_picker/image_picker.dart';
import 'package:geolocator/geolocator.dart';
import 'package:geocoding/geocoding.dart';
import '../services/tflite_service.dart';
import '../services/api_service.dart';

class ReportDamageScreen extends StatefulWidget {
  const ReportDamageScreen({super.key});

  @override
  State<ReportDamageScreen> createState() => _ReportDamageScreenState();
}

class _ReportDamageScreenState extends State<ReportDamageScreen> {
  String _selectedDamageType = 'Pothole';
  final TextEditingController _descriptionController = TextEditingController();

  final List<String> _damageTypes = [
    'Pothole',
    'Crack',
    'Faded Lines',
    'Other',
  ];

  // --- VARIABLES ---
  File? _selectedImage;
  final ImagePicker _picker = ImagePicker();
  final TFLiteService _tfliteService = TFLiteService();
  
  String _currentAddress = "Locating your position...";
  double? _currentLat;
  double? _currentLng;
  bool _isLoadingLocation = true;
  bool _isSubmitting = false;

  @override
  void initState() {
    super.initState();
    _tfliteService.initializeModel();
    _getCurrentLocation();
  }

  // --- GPS FUNCTION ---
  Future<void> _getCurrentLocation() async {
    bool serviceEnabled;
    LocationPermission permission;

    serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      setState(() {
        _currentAddress = 'GPS is turned off.';
        _isLoadingLocation = false;
      });
      return;
    }

    permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) {
        setState(() {
          _currentAddress = 'Location permission denied.';
          _isLoadingLocation = false;
        });
        return;
      }
    }

    try {
      Position position = await Geolocator.getCurrentPosition(
          desiredAccuracy: LocationAccuracy.high);
      
      List<Placemark> placemarks = await placemarkFromCoordinates(
          position.latitude, position.longitude);
      Placemark place = placemarks[0];

      setState(() {
        _currentAddress = "${place.street}, ${place.locality}, ${place.country}";
        _currentLat = position.latitude;
        _currentLng = position.longitude;
        _isLoadingLocation = false;
      });
    } catch (e) {
      setState(() {
        _currentAddress = 'Failed to get location.';
        _isLoadingLocation = false;
      });
    }
  }

  // --- CAMERA FUNCTION ---
  Future<void> _pickImage(ImageSource source) async {
    final XFile? pickedFile = await _picker.pickImage(
      source: source,
      imageQuality: 50, 
      maxWidth: 800,
    );

    if (pickedFile != null) {
      setState(() {
        _selectedImage = File(pickedFile.path);
      });
      print("📸 Image selected: ${pickedFile.path}");

      print("🤖 AI is analyzing the image...");
      String detectedDamage = await _tfliteService.predictImage(pickedFile.path);

      print("✅ AI finished! It looks like a: $detectedDamage");
    }
  }

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
          'Confirm Report',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 20),
        ),
        centerTitle: true,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // --- IMAGE PREVIEW BOX ---
            GestureDetector(
              onTap: () {
                FocusScope.of(context).unfocus();
                showModalBottomSheet(
                  context: context,
                  backgroundColor: const Color(0xFF1E1E1E),
                  shape: const RoundedRectangleBorder(
                    borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
                  ),
                  builder: (context) => SafeArea(
                    child: Wrap(
                      children: [
                        ListTile(
                          leading: const Icon(Icons.camera_alt, color: Color(0xFFFFD700)),
                          title: const Text('Take a Photo', style: TextStyle(color: Colors.white)),
                          onTap: () {
                            Navigator.of(context).pop();
                            _pickImage(ImageSource.camera);
                          },
                        ),
                        ListTile(
                          leading: const Icon(Icons.photo_library, color: Color(0xFFFFD700)),
                          title: const Text('Choose from Gallery', style: TextStyle(color: Colors.white)),
                          onTap: () {
                            Navigator.of(context).pop();
                            _pickImage(ImageSource.gallery);
                          },
                        ),
                      ],
                    ),
                  ),
                );
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
                    : const Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.add_a_photo, color: Colors.white54, size: 50),
                          SizedBox(height: 12),
                          Text('Tap to add photo of the damage', style: TextStyle(color: Colors.white54, fontSize: 16)),
                        ],
                      ),
              ),
            ),

            const SizedBox(height: 30),

            // --- LOCATION ---
            _buildSectionTitle('Location'),
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
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFFFFD700)),
                    )
                ],
              ),
            ),

            const SizedBox(height: 30),

            // --- DETAILS ---
            _buildSectionTitle('Details'),
            const SizedBox(height: 12),
            const Text('Type of Damage', style: TextStyle(color: Colors.white70, fontSize: 14)),
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
                      child: Text(type),
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

            // --- SUBMIT BUTTON ---
            SizedBox(
              width: double.infinity,
              height: 55,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFFFFD700),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                onPressed: _isSubmitting ? null : () async {
                  // 1. Check if they took a photo
                  if (_selectedImage == null) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Please add a photo of the damage first!')),
                    );
                    return;
                  }

                  // 2. Show the loading spinner
                  setState(() {
                    _isSubmitting = true;
                  });

                  try {
                    print("🚀 Preparing to send report for $_selectedDamageType at $_currentAddress");
                    
                    // Make sure GPS finished loading!
                    if (_currentLat == null || _currentLng == null) {
                       ScaffoldMessenger.of(context).showSnackBar(
                         const SnackBar(content: Text('Still getting your location, please wait a second!')),
                       );
                       return;
                    }

                    // 3. THE REAL API CONNECTION!
                    bool success = await ApiService.submitReport(
                      photo: XFile(_selectedImage!.path), 
                      latitude: _currentLat!,
                      longitude: _currentLng!,
                      typeId: _getDamageTypeId(_selectedDamageType),
                    );

                    if (!mounted) return;

                    // 4. Check if the database accepted it
                    if (success) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('✅ Report submitted successfully!'),
                          backgroundColor: Colors.green,
                        ),
                      );
                      Navigator.pop(context); // Closes the screen and returns to map
                    } else {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('❌ Failed to upload to the server.'),
                          backgroundColor: Colors.red,
                        ),
                      );
                    }

                  } catch (e) {
                    if (!mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('Failed to submit: $e'), backgroundColor: Colors.red),
                    );
                  } finally {
                    if (mounted) {
                      setState(() {
                        _isSubmitting = false;
                      });
                    }
                  }
                },
                child: _isSubmitting 
                    ? const SizedBox(
                        height: 24, 
                        width: 24, 
                        child: CircularProgressIndicator(color: Colors.black, strokeWidth: 3)
                      )
                    : const Text(
                        'Submit Report',
                        style: TextStyle(color: Colors.black, fontSize: 18, fontWeight: FontWeight.bold),
                      ),
              ),
            ),
            
            const SizedBox(height: 40),
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

  // --- TRANSLATE STRING TO ID ---
  int _getDamageTypeId(String type) {
    switch (type) {
      case 'Pothole': return 1;
      case 'Crack': return 2;
      case 'Faded Lines': return 3;
      default: return 4; // 'Other'
    }
  }
}