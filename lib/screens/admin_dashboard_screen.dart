import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl_phone_field/intl_phone_field.dart';
import '../services/api_service.dart';

class AdminDashboardScreen extends StatefulWidget {
  const AdminDashboardScreen({super.key});

  @override
  State<AdminDashboardScreen> createState() => _AdminDashboardScreenState();
}

class _AdminDashboardScreenState extends State<AdminDashboardScreen> with SingleTickerProviderStateMixin {
  late TabController _tabController;
  final bool isSuperAdmin = ApiService.loggedInRole == 'SuperAdmin';
  final bool isArabic = ApiService.currentLanguage == 'ar';

  // --- State for Users Tab ---
  final TextEditingController _nationalIdController = TextEditingController();
  final TextEditingController _dobController = TextEditingController();
  final TextEditingController _phoneController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  bool _isLoadingAuth = false;

  String _fullPhoneNumber = '';

  // State for Reports Tab
  List<Hazard> _hazards = [];
  bool _isLoadingReports = true;
  int _selectedFilterStatus = 0; 

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _loadReports();
  }

  Future<void> _loadReports() async {
    setState(() => _isLoadingReports = true);
    final data = await ApiService.fetchHazards();
    setState(() {
      _hazards = data;
      _isLoadingReports = false;
    });
  }

  // ==========================================
  // TAB 1: REPORT MANAGEMENT
  // ==========================================
  Widget _buildReportsTab() {
    if (_isLoadingReports) {
      return const Center(child: CircularProgressIndicator(color: Color(0xFFFFD700)));
    }

    List<Hazard> displayHazards = _selectedFilterStatus == 0 
        ? _hazards 
        : _hazards.where((h) => h.statusId == _selectedFilterStatus).toList();

    return Column(
      children: [
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
        
        Expanded(
          child: displayHazards.isEmpty
              ? Center(child: Text(isArabic ? 'لا توجد بلاغات' : 'No reports found', style: const TextStyle(color: Colors.white54)))
              : ListView.builder(
                  padding: const EdgeInsets.all(16),
                  itemCount: displayHazards.length,
                  itemBuilder: (context, index) {
                    final hazard = displayHazards[index];
                    return Card(
                      color: Colors.white.withValues(alpha: 0.05),
                      margin: const EdgeInsets.only(bottom: 16),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: BorderSide(color: Colors.white.withValues(alpha: 0.1))),
                      child: Padding(
                        padding: const EdgeInsets.all(16.0),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text('Report ID: ${hazard.id.substring(0, 8)}...', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                  decoration: BoxDecoration(color: hazard.severityColor.withValues(alpha: 0.2), borderRadius: BorderRadius.circular(8)),
                                  child: Text('Status: ${hazard.statusId}', style: TextStyle(color: hazard.severityColor, fontWeight: FontWeight.bold, fontSize: 12)),
                                )
                              ],
                            ),
                            const SizedBox(height: 12),
                            const Text('Change Status:', style: TextStyle(color: Colors.white54, fontSize: 12)),
                            const SizedBox(height: 8),
                            Wrap(
                              spacing: 8, runSpacing: 8,
                              children: [
                                _statusButton(hazard.id, 2, isArabic ? 'قيد العمل' : 'In Progress', Colors.blue),
                                _statusButton(hazard.id, 3, isArabic ? 'محلول' : 'Resolved', Colors.green),
                                _statusButton(hazard.id, 4, isArabic ? 'خطأ ذكاء اصطناعي' : 'AI Error (Wrong)', Colors.red), 
                              ],
                            )
                          ],
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

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
          _loadReports(); 
        } else {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('❌ Failed to update status'), backgroundColor: Colors.red, behavior: SnackBarBehavior.floating));
        }
      },
    );
  }

  // ==========================================
  // TAB 2: USER MANAGEMENT 
  // ==========================================
  Widget _buildUsersTab() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(isArabic ? 'إنشاء حساب جديد' : 'Create New Account', style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          Text(isArabic ? "يرجى إدخال البيانات كما هي في الهوية" : "Please enter details exactly as on ID", style: const TextStyle(color: Colors.white54, fontSize: 14)),
          const SizedBox(height: 20),
          
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
          
          // --- NEW: INTL PHONE FIELD WITH FLAGS ---
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
            label: isArabic ? "كلمة المرور" : "Password",
            icon: Icons.lock,
            isPassword: true,
          ),
          
          const SizedBox(height: 24),
          
          _isLoadingAuth 
            ? const Center(child: CircularProgressIndicator(color: Color(0xFFFFD700)))
            : Column(
                children: [
                  SizedBox(
                    width: double.infinity, height: 50,
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFFFD700), foregroundColor: Colors.black, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
                      onPressed: () => _handleCreateAccount(false),
                      child: Text(isArabic ? 'إنشاء حساب مواطن' : 'Create Citizen User', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                    ),
                  ),
                  const SizedBox(height: 16),
                  
                  if (isSuperAdmin)
                    SizedBox(
                      width: double.infinity, height: 50,
                      child: ElevatedButton(
                        style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent, foregroundColor: Colors.white, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
                        onPressed: () => _handleCreateAccount(true),
                        child: Text(isArabic ? 'إنشاء حساب مسؤول' : 'Create Admin Account', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                      ),
                    ),
                ],
              )
        ],
      ),
    );
  }

  // --- Helper Methods ---
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
    if (_nationalIdController.text.length != 10 || _passwordController.text.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Please enter a 10-digit ID and password.'), backgroundColor: Colors.red, behavior: SnackBarBehavior.floating));
      return;
    }

    setState(() => _isLoadingAuth = true);
    
    // Synthetic email trick
    String syntheticEmail = "${_nationalIdController.text.trim()}@rased.com";
    
    // NOTE: If backend adds a phone number field later, you can use _fullPhoneNumber variable here!
    
    bool success;
    if (isAdmin) {
      success = await ApiService.registerAdmin(syntheticEmail, _passwordController.text.trim(), _nationalIdController.text.trim());
    } else {
      success = await ApiService.registerUser(syntheticEmail, _passwordController.text.trim(), _nationalIdController.text.trim());
    }

    setState(() => _isLoadingAuth = false);

    if (success) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('✅ Account Created!'), backgroundColor: Colors.green, behavior: SnackBarBehavior.floating));
      _nationalIdController.clear();
      _passwordController.clear();
      _dobController.clear();
      _phoneController.clear();
    } else {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('❌ Failed to create account'), backgroundColor: Colors.red, behavior: SnackBarBehavior.floating));
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
          title: Text(isArabic ? 'لوحة التحكم' : 'Control Panel', style: const TextStyle(color: Color(0xFFFFD700), fontWeight: FontWeight.bold)),
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