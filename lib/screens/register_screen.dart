import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/api_service.dart';

class RegisterScreen extends StatefulWidget {
  final String language;
  const RegisterScreen({super.key, required this.language});

  @override
  State<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends State<RegisterScreen> {
  final TextEditingController _nationalIdController = TextEditingController();
  final TextEditingController _dobController = TextEditingController();
  final TextEditingController _phoneController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  
  bool _isLoading = false;

  void _handleRegister() async {
    final isArabic = widget.language == 'ar';

    // 1. Validate the National ID
    if (_nationalIdController.text.length != 10) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(isArabic ? 'الرقم الوطني يجب أن يتكون من 10 أرقام' : 'National ID must be 10 digits'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    // 2. Validate Password
    if (_passwordController.text.isEmpty) {
       ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(isArabic ? 'يرجى إدخال كلمة المرور' : 'Please enter a password'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    setState(() => _isLoading = true);

    // 3. THE MAGIC TRICK: Create the synthetic email
    String syntheticEmail = "${_nationalIdController.text.trim()}@rased.com";
    
    print("🚀 Sending to database as: $syntheticEmail");

    // 4. Send ALL THREE fields to the API!
    bool success = await ApiService.registerUser(
      syntheticEmail,
      _passwordController.text.trim(),
      _nationalIdController.text.trim()
    );

    if (!mounted) return;
    setState(() => _isLoading = false);

    if (success) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(isArabic ? '✅ تم التسجيل بنجاح!' : '✅ Registration Successful!'),
          backgroundColor: Colors.green,
        ),
      );
      
      // Go back to the login screen so they can log in
      Navigator.pop(context);
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(isArabic ? '❌ فشل التسجيل، قد يكون الرقم الوطني مسجلاً مسبقاً' : '❌ Registration failed. ID might already exist.'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

// --- CALENDAR POPUP ---
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
              primary: Color(0xFFFFD700), // Header background color
              onPrimary: Colors.black,    // Header text color
              surface: Color(0xFF1E1E1E), // Background color
              onSurface: Colors.white,    // Calendar text color
            ),
            textButtonTheme: TextButtonThemeData(
              style: TextButton.styleFrom(
                foregroundColor: const Color(0xFFFFD700), // OK/Cancel button color
              ),
            ),
          ),
          child: child!,
        );
      },
    );

    // If they picked a date, format it and put it in the text box
    if (picked != null) {
      setState(() {
        String formattedDate = "${picked.year}-${picked.month.toString().padLeft(2, '0')}-${picked.day.toString().padLeft(2, '0')}";
        _dobController.text = formattedDate;
      });
    }
  }

  // Quick helper to build identical text fields
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
          enabledBorder: OutlineInputBorder(
            borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.2)),
            borderRadius: BorderRadius.circular(10),
          ),
          focusedBorder: OutlineInputBorder(
            borderSide: const BorderSide(color: Color(0xFFFFD700)),
            borderRadius: BorderRadius.circular(10),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isArabic = widget.language == 'ar';

    return Scaffold(
      backgroundColor: const Color(0xFF121212),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24.0),
          child: Directionality(
            textDirection: isArabic ? TextDirection.rtl : TextDirection.ltr,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.verified_user, size: 80, color: Color(0xFFFFD700)),
                const SizedBox(height: 16),
                Text(
                  isArabic ? "إنشاء حساب جديد" : "Create Account",
                  style: const TextStyle(color: Colors.white, fontSize: 28, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),
                Text(
                  isArabic ? "يرجى إدخال بياناتك كما هي في الهوية" : "Please enter details exactly as on your ID",
                  style: const TextStyle(color: Colors.white54, fontSize: 14),
                ),
                const SizedBox(height: 30),

                ClipRRect(
                  borderRadius: BorderRadius.circular(20),
                  child: BackdropFilter(
                    filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
                    child: Container(
                      padding: const EdgeInsets.all(24),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.05),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
                      ),
                      child: Column(
                        children: [
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
                          _buildTextField(
                            controller: _phoneController,
                            label: isArabic ? "رقم الهاتف" : "Phone Number",
                            icon: Icons.phone,
                            keyboardType: TextInputType.phone,
                          ),
                          _buildTextField(
                            controller: _passwordController,
                            label: isArabic ? "كلمة المرور" : "Password",
                            icon: Icons.lock,
                            isPassword: true,
                          ),
                          const SizedBox(height: 10),
                          SizedBox(
                            width: double.infinity,
                            height: 50,
                            child: ElevatedButton(
                              onPressed: _isLoading ? null : _handleRegister,
                              style: ElevatedButton.styleFrom(
                                backgroundColor: const Color(0xFFFFD700),
                                foregroundColor: Colors.black,
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                              ),
                              child: _isLoading
                                  ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(color: Colors.black, strokeWidth: 2))
                                  : Text(
                                      isArabic ? "التحقق من الهوية والتسجيل" : "Verify Identity & Register",
                                      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                                    ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}