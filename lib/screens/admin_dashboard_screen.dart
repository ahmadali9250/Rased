import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl_phone_field/intl_phone_field.dart';
import 'package:geocoding/geocoding.dart'; // <-- NEW: For translating coordinates to addresses!
import '../services/api_service.dart';

/// The Central Command Dashboard for Admins and SuperAdmins.
///
/// Features two main tabs:
/// 1. Report Management: View, filter, and change the status of citizen hazard reports.
/// 2. User Management: Register new Citizens, or (if SuperAdmin) register new Admins.
class AdminDashboardScreen extends StatefulWidget {
  const AdminDashboardScreen({super.key});

  @override
  State<AdminDashboardScreen> createState() => _AdminDashboardScreenState();
}

class _AdminDashboardScreenState extends State<AdminDashboardScreen> with SingleTickerProviderStateMixin {
  late TabController _tabController;
  final bool isSuperAdmin = ApiService.loggedInRole == 'SuperAdmin';
  final bool isArabic = ApiService.currentLanguage == 'ar';

  // ==========================================
  // TAB 1 STATE: REPORT MANAGEMENT
  // ==========================================
  List<Hazard> _hazards = [];
  bool _isLoadingReports = true;
  int _selectedFilterStatus = 0; // 0 = All, 2 = In Progress, 3 = Resolved, 4 = AI Error

  // ==========================================
  // TAB 2 STATE: USER MANAGEMENT
  // ==========================================
  final TextEditingController _nationalIdController = TextEditingController();
  final TextEditingController _dobController = TextEditingController();
  final TextEditingController _phoneController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  
  bool _isLoadingAuth = false;
  String _fullPhoneNumber = ''; // Stores the complete intl number (e.g., +962791234567)

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _loadReports();
  }

  /// Fetches the global list of hazards from the backend.
  Future<void> _loadReports() async {
    setState(() => _isLoadingReports = true);
    final data = await ApiService.fetchHazards();
    
    if (mounted) {
      setState(() {
        _hazards = data;
        _isLoadingReports = false;
      });
    }
  }

  // ==========================================
  // TAB 1: REPORT MANAGEMENT UI
  // ==========================================
  
  Widget _buildReportsTab() {
    if (_isLoadingReports) {
      return const Center(child: CircularProgressIndicator(color: Color(0xFFFFD700)));
    }

    // Apply the active filter (All vs In Progress vs Resolved)
    List<Hazard> displayHazards = _selectedFilterStatus == 0 
        ? _hazards 
        : _hazards.where((h) => h.statusId == _selectedFilterStatus).toList();

    return Column(
      children: [
        // --- HORIZONTAL FILTER BAR ---
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            children: [
              _filterChip(0, isArabic ? 'الكل' : 'All', Colors.white),
              const SizedBox(width: 8),
              _filterChip(2, isArabic ? 'قيد العمل' : 'In Progress', Colors.blue),
              const SizedBox(width: 8),
              _filterChip(3, isArabic ? 'محلول' : 'Resolved', Colors.green),
              const SizedBox(width: 8),
              _filterChip(4, isArabic ? 'خطأ ذكاء اصطناعي' : 'AI Error', Colors.red),
            ],
          ),
        ),
        
        // --- LIST OF REPORTS ---
        Expanded(
          child: displayHazards.isEmpty
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.check_circle_outline, size: 80, color: Colors.white24),
                      const SizedBox(height: 16),
                      Text(isArabic ? 'لا توجد بلاغات حالياً' : 'No reports found', style: const TextStyle(color: Colors.white54, fontSize: 18)),
                    ],
                  )
                )
              : ListView.builder(
                  padding: const EdgeInsets.only(left: 16, right: 16, bottom: 40),
                  itemCount: displayHazards.length,
                  itemBuilder: (context, index) {
                    final hazard = displayHazards[index];
                    return _buildAdminReportCard(hazard);
                  },
                ),
        ),
      ],
    );
  }

  /// Builds a comprehensive, interactive card for an admin to review a specific hazard.
  Widget _buildAdminReportCard(Hazard hazard) {
    final String typeName = _getHazardName(hazard.typeId, isArabic);
    final String statusText = _getStatusText(hazard.statusId, isArabic);
    final Color statusColor = _getStatusColor(hazard.statusId);

    return Card(
      color: Colors.white.withValues(alpha: 0.05),
      margin: const EdgeInsets.only(bottom: 16),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16), 
        side: BorderSide(color: Colors.white.withValues(alpha: 0.1))
      ),
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header Row: Type & Status
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  typeName, 
                  style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)
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
                    style: TextStyle(color: statusColor, fontWeight: FontWeight.bold, fontSize: 12)
                  ),
                )
              ],
            ),
            const SizedBox(height: 16),

            // Main Content Row: Image + Details
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Image Thumbnail
                ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: Container(
                    width: 100, height: 100,
                    color: Colors.black26,
                    child: hazard.fullImageUrl != null
                        ? Image.network(
                            hazard.fullImageUrl!, fit: BoxFit.cover,
                            errorBuilder: (context, error, stack) => const Icon(Icons.broken_image, color: Colors.white38),
                          )
                        : const Icon(Icons.image_not_supported, color: Colors.white38),
                  ),
                ),
                const SizedBox(width: 16),

                // Details Column
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('ID: ${hazard.id.substring(0, 8)}...', style: const TextStyle(color: Colors.white54, fontSize: 12, fontFamily: 'monospace')),
                      const SizedBox(height: 8),
                      
                      // Translated Address!
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Icon(Icons.location_on, color: Color(0xFFFFD700), size: 16),
                          const SizedBox(width: 4),
                          Expanded(
                            child: FutureBuilder<String>(
                              future: _getAddress(hazard.location.latitude, hazard.location.longitude),
                              builder: (context, snapshot) {
                                if (snapshot.connectionState == ConnectionState.waiting) {
                                  return Text(isArabic ? 'جاري ترجمة الموقع...' : 'Translating GPS...', style: const TextStyle(color: Colors.white54, fontSize: 12, fontStyle: FontStyle.italic));
                                }
                                return Text(snapshot.data ?? 'Unknown', style: const TextStyle(color: Colors.white70, fontSize: 13));
                              },
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      
                      Row(
                        children: [
                          const Icon(Icons.people, color: Color(0xFFFFD700), size: 16),
                          const SizedBox(width: 4),
                          Text(
                            isArabic ? 'عدد التبليغات: ${hazard.detectionCount}' : 'Reports: ${hazard.detectionCount}', 
                            style: const TextStyle(color: Colors.white70, fontSize: 13)
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),

            const SizedBox(height: 20),
            const Divider(color: Colors.white24),
            const SizedBox(height: 12),

            // Action Buttons
            Text(isArabic ? 'تحديث حالة البلاغ:' : 'Update Status:', style: const TextStyle(color: Colors.white54, fontSize: 12, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8, runSpacing: 8,
              children: [
                if (hazard.statusId != 2) _statusButton(hazard.id, 2, isArabic ? 'قيد العمل' : 'In Progress', Colors.blue),
                if (hazard.statusId != 3) _statusButton(hazard.id, 3, isArabic ? 'محلول' : 'Resolved', Colors.green),
                if (hazard.statusId != 4) _statusButton(hazard.id, 4, isArabic ? 'خطأ ذكاء اصطناعي' : 'AI False Positive', Colors.red), 
              ],
            )
          ],
        ),
      ),
    );
  }

  // ==========================================
  // TAB 2: USER MANAGEMENT UI
  // ==========================================
  
  Widget _buildUsersTab() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.person_add_alt_1, color: Color(0xFFFFD700), size: 30),
              const SizedBox(width: 12),
              Text(isArabic ? 'إنشاء حساب جديد' : 'Create New Account', style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.bold)),
            ],
          ),
          const SizedBox(height: 8),
          Text(isArabic ? "يرجى إدخال البيانات كما هي في الهوية" : "Please enter details exactly as on ID", style: const TextStyle(color: Colors.white54, fontSize: 14)),
          const SizedBox(height: 30),
          
          _buildTextField(
            controller: _nationalIdController,
            label: isArabic ? "الرقم الوطني (10 أرقام)" : "National ID (10 digits)",
            icon: Icons.badge,
            keyboardType: TextInputType.number,
            formatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(10)],
          ),
          _buildTextField(
            controller: _dobController,
            label: isArabic ? "تاريخ الميلاد (YYYY-MM-DD)" : "Date of Birth (YYYY-MM-DD)",
            icon: Icons.calendar_today,
            readOnly: true,
            onTap: () => _selectDate(context),
          ),
          
          // Official Standardized Phone Field
          Padding(
            padding: const EdgeInsets.only(bottom: 16.0),
            child: IntlPhoneField(
              controller: _phoneController,
              dropdownIcon: const Icon(Icons.arrow_drop_down, color: Color(0xFFFFD700)),
              dropdownTextStyle: const TextStyle(color: Colors.white, fontSize: 16),
              style: const TextStyle(color: Colors.white),
              initialCountryCode: 'JO',
              decoration: InputDecoration(
                labelText: isArabic ? "رقم الهاتف" : "Phone Number",
                labelStyle: const TextStyle(color: Colors.white54),
                enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.2)), borderRadius: BorderRadius.circular(10)),
                focusedBorder: OutlineInputBorder(borderSide: const BorderSide(color: Color(0xFFFFD700)), borderRadius: BorderRadius.circular(10)),
              ),
              onChanged: (phone) {
                _fullPhoneNumber = phone.completeNumber; 
              },
            ),
          ),
          
          _buildTextField(
            controller: _passwordController,
            label: isArabic ? "كلمة المرور المؤقتة" : "Temporary Password",
            icon: Icons.lock,
            isPassword: true,
          ),
          
          const SizedBox(height: 30),
          
          // Action Buttons
          _isLoadingAuth 
            ? const Center(child: CircularProgressIndicator(color: Color(0xFFFFD700)))
            : Column(
                children: [
                  SizedBox(
                    width: double.infinity, height: 50,
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFFFD700), foregroundColor: Colors.black, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
                      onPressed: () => _handleCreateAccount(false),
                      child: Text(isArabic ? 'إنشاء حساب مواطن' : 'Create Citizen Account', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                    ),
                  ),
                  const SizedBox(height: 16),
                  
                  // Only SuperAdmins can mint other Admins!
                  if (isSuperAdmin)
                    SizedBox(
                      width: double.infinity, height: 50,
                      child: ElevatedButton.icon(
                        icon: const Icon(Icons.security, size: 20),
                        style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent, foregroundColor: Colors.white, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
                        onPressed: () => _handleCreateAccount(true),
                        label: Text(isArabic ? 'ترقية لحساب مسؤول' : 'Create Admin Account', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                      ),
                    ),
                ],
              )
        ],
      ),
    );
  }

  // ==========================================
  // HELPER METHODS
  // ==========================================

  Widget _filterChip(int statusId, String label, Color color) {
    final isSelected = _selectedFilterStatus == statusId;
    return ChoiceChip(
      label: Text(label, style: TextStyle(color: isSelected ? Colors.black : color, fontWeight: FontWeight.bold)),
      selected: isSelected,
      selectedColor: color,
      backgroundColor: Colors.transparent,
      side: BorderSide(color: color),
      onSelected: (bool selected) {
        if (selected) setState(() => _selectedFilterStatus = statusId);
      },
    );
  }

  Widget _statusButton(String id, int newStatus, String label, Color color) {
    return ActionChip(
      backgroundColor: color.withValues(alpha: 0.1),
      side: BorderSide(color: color),
      label: Text(label, style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.bold)),
      onPressed: () async {
        bool success = await ApiService.updateHazardStatus(id, newStatus);
        if (success) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('✅ Status Updated!'), backgroundColor: Colors.green, behavior: SnackBarBehavior.floating));
          _loadReports(); // Refresh the list!
        } else {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('❌ Failed to update status'), backgroundColor: Colors.red, behavior: SnackBarBehavior.floating));
        }
      },
    );
  }

  Future<String> _getAddress(double lat, double lng) async {
    try {
      List<Placemark> placemarks = await placemarkFromCoordinates(lat, lng);
      if (placemarks.isNotEmpty) {
        Placemark place = placemarks.first;
        return "${place.street}, ${place.locality}";
      }
    } catch (e) {
      debugPrint("Address Error: $e");
    }
    return "${lat.toStringAsFixed(4)}, ${lng.toStringAsFixed(4)}";
  }

  String _getStatusText(int statusId, bool isArabic) {
    switch (statusId) {
      case 1: return isArabic ? 'قيد المراجعة' : 'Pending';
      case 2: return isArabic ? 'قيد العمل' : 'In Progress';
      case 3: return isArabic ? 'محلول' : 'Resolved';
      case 4: return isArabic ? 'مرفوض' : 'Rejected (AI)';
      default: return isArabic ? 'غير معروف' : 'Unknown';
    }
  }

  Color _getStatusColor(int statusId) {
    switch (statusId) {
      case 1: return const Color(0xFFFFD700); 
      case 2: return Colors.blueAccent;       
      case 3: return Colors.greenAccent;      
      case 4: return Colors.redAccent;        
      default: return Colors.grey;
    }
  }

  String _getHazardName(int typeId, bool isArabic) {
    switch (typeId) {
      case 1: return isArabic ? 'حفرة' : 'Pothole';
      case 2: return isArabic ? 'تشقق' : 'Crack';
      case 3: return isArabic ? 'خطوط باهتة' : 'Faded Lines';
      case 4: return isArabic ? 'مناهل مكسورة' : 'Broken Manhole';
      default: return isArabic ? 'نوع غير معروف' : 'Unknown Hazard';
    }
  }

  Future<void> _selectDate(BuildContext context) async {
    final DateTime? picked = await showDatePicker(
      context: context,
      initialDate: DateTime(2000, 1, 1),
      firstDate: DateTime(1900),
      lastDate: DateTime.now(),
      builder: (context, child) {
        return Theme(
          data: Theme.of(context).copyWith(
            colorScheme: const ColorScheme.dark(
              primary: Color(0xFFFFD700), onPrimary: Colors.black, surface: Color(0xFF1E1E1E), onSurface: Colors.white,
            ),
            textButtonTheme: TextButtonThemeData(style: TextButton.styleFrom(foregroundColor: const Color(0xFFFFD700))),
          ),
          child: child!,
        );
      },
    );

    if (picked != null) {
      setState(() {
        _dobController.text = "${picked.year}-${picked.month.toString().padLeft(2, '0')}-${picked.day.toString().padLeft(2, '0')}";
      });
    }
  }

  Widget _buildTextField({
    required TextEditingController controller,
    required String label,
    required IconData icon,
    bool isPassword = false,
    TextInputType keyboardType = TextInputType.text,
    List<TextInputFormatter>? formatters,
    bool readOnly = false,
    VoidCallback? onTap,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16.0),
      child: TextField(
        controller: controller,
        obscureText: isPassword,
        keyboardType: keyboardType,
        inputFormatters: formatters,
        readOnly: readOnly,
        onTap: onTap,
        style: const TextStyle(color: Colors.white),
        decoration: InputDecoration(
          labelText: label,
          labelStyle: const TextStyle(color: Colors.white54),
          prefixIcon: Icon(icon, color: Colors.white54),
          enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.2)), borderRadius: BorderRadius.circular(10)),
          focusedBorder: OutlineInputBorder(borderSide: const BorderSide(color: Color(0xFFFFD700)), borderRadius: BorderRadius.circular(10)),
        ),
      ),
    );
  }

  void _handleCreateAccount(bool isAdmin) async {
    final isArabic = ApiService.currentLanguage == 'ar';

    if (_nationalIdController.text.length != 10 || _passwordController.text.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(isArabic ? '❌ يرجى إدخال الرقم الوطني وكلمة المرور!' : '❌ Please enter a 10-digit ID and password.'), backgroundColor: Colors.red, behavior: SnackBarBehavior.floating));
      return;
    }

    setState(() => _isLoadingAuth = true);
    
    String syntheticEmail = "${_nationalIdController.text.trim()}@rased.com";
    
    bool success;
    if (isAdmin) {
      success = await ApiService.registerAdmin(syntheticEmail, _passwordController.text.trim(), _nationalIdController.text.trim());
    } else {
      success = await ApiService.registerUser(syntheticEmail, _passwordController.text.trim(), _nationalIdController.text.trim());
    }

    setState(() => _isLoadingAuth = false);

    if (success) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(isArabic ? '✅ تم إنشاء الحساب بنجاح!' : '✅ Account Created!'), backgroundColor: Colors.green, behavior: SnackBarBehavior.floating));
      _nationalIdController.clear();
      _passwordController.clear();
      _dobController.clear();
      _phoneController.clear();
    } else {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(isArabic ? '❌ فشل إنشاء الحساب' : '❌ Failed to create account'), backgroundColor: Colors.red, behavior: SnackBarBehavior.floating));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: isArabic ? TextDirection.rtl : TextDirection.ltr,
      child: Scaffold(
        backgroundColor: const Color(0xFF121212),
        appBar: AppBar(
          backgroundColor: const Color(0xFF1A1A1A),
          title: Text(isArabic ? 'لوحة تحكم المسؤول' : 'Admin Control Panel', style: const TextStyle(color: Color(0xFFFFD700), fontWeight: FontWeight.bold)),
          iconTheme: const IconThemeData(color: Colors.white),
          bottom: TabBar(
            controller: _tabController,
            indicatorColor: const Color(0xFFFFD700),
            labelColor: const Color(0xFFFFD700),
            unselectedLabelColor: Colors.white54,
            tabs: [
              Tab(icon: const Icon(Icons.report_problem), text: isArabic ? 'البلاغات' : 'Reports'),
              Tab(icon: const Icon(Icons.people), text: isArabic ? 'المستخدمين' : 'Users'),
            ],
          ),
        ),
        body: TabBarView(
          controller: _tabController,
          children: [
            _buildReportsTab(),
            _buildUsersTab(),
          ],
        ),
      ),
    );
  }
}