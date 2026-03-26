import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:country_picker/country_picker.dart';
import 'map_screen.dart';
import '../services/api_service.dart';
import 'register_screen.dart';

/// The initial authentication screen for the Rased (راصد) application.
/// 
/// Handles user login via National ID, language toggling, and password recovery.
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final TextEditingController _emailController = TextEditingController(); // Stores National ID
  final TextEditingController _passwordController = TextEditingController();
  bool _isLoading = false;

  late String _language = ApiService.currentLanguage;

  /// Toggles the global application language between English and Arabic.
  void _toggleLanguage() {
    setState(() {
      _language = _language == 'en' ? 'ar' : 'en';
      ApiService.currentLanguage = _language;
    });
  }

  /// Processes the login request.
  /// 
  /// Converts the National ID into a synthetic email (`[ID]@rased.com`) 
  /// to authenticate seamlessly with the backend identity framework.
  void _handleLogin() async {
    final isArabic = _language == 'ar';

    // 1. Validate inputs to prevent unnecessary API calls
    if (_emailController.text.isEmpty || _passwordController.text.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            isArabic
                ? 'الرجاء إدخال الرقم الوطني وكلمة المرور'
                : 'Please enter your National ID and password',
          ),
          backgroundColor: Colors.red,
          behavior: SnackBarBehavior.floating, // Floats cleanly over UI
        ),
      );
      return;
    }

    setState(() => _isLoading = true);

    // 2. THE MAGIC TRICK: Append @rased.com to the National ID
    String syntheticEmail = "${_emailController.text.trim()}@rased.com";
    debugPrint("🚀 Attempting to log in as: $syntheticEmail");

    // 3. Authenticate against the C# backend
    bool success = await ApiService.login(
      syntheticEmail,
      _passwordController.text.trim(),
    );

    if (!mounted) return;
    setState(() => _isLoading = false);

    // 4. Handle authentication response
    if (success) {
      ApiService.currentLanguage = _language; // Lock in the language preference

      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (context) => const MapScreen()),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            isArabic
                ? '❌ الرقم الوطني أو كلمة المرور غير صحيحة!'
                : '❌ Invalid National ID or password!',
          ),
          backgroundColor: Colors.red,
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  // ==========================================
  // FORGOT PASSWORD FLOW
  // ==========================================

  /// Step 1: Shows a dialog allowing the user to choose their recovery method (Email or SMS).
  void _showForgotPasswordChoiceDialog() {
    final isArabic = ApiService.currentLanguage == 'ar';

    showDialog(
      context: context,
      builder: (context) {
        return Directionality(
          textDirection: isArabic ? TextDirection.rtl : TextDirection.ltr,
          child: AlertDialog(
            backgroundColor: const Color(0xFF1E1E1E),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            title: Text(
              isArabic ? "طريقة استعادة كلمة المرور" : "Reset Password Method",
              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Option 1: Email Recovery
                ListTile(
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  tileColor: Colors.white.withValues(alpha: 0.05),
                  leading: const Icon(Icons.email, color: Color(0xFFFFD700)),
                  title: Text(isArabic ? "البريد الإلكتروني" : "Email", style: const TextStyle(color: Colors.white)),
                  onTap: () {
                    Navigator.pop(context);
                    _showResetInputDialog("email");
                  },
                ),
                const SizedBox(height: 12),
                
                // Option 2: SMS Recovery
                ListTile(
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  tileColor: Colors.white.withValues(alpha: 0.05),
                  leading: const Icon(Icons.sms, color: Color(0xFFFFD700)),
                  title: Text(isArabic ? "رسالة نصية (SMS)" : "SMS", style: const TextStyle(color: Colors.white)),
                  onTap: () {
                    Navigator.pop(context);
                    _showResetInputDialog("sms");
                  },
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: Text(isArabic ? "إلغاء" : "Cancel", style: const TextStyle(color: Colors.white54)),
              ),
            ],
          ),
        );
      },
    );
  }

  /// Step 2: Shows the input dialog for the selected recovery method.
  /// Dynamically changes the input type and prefix icon based on [method].
  void _showResetInputDialog(String method) {
    final isArabic = ApiService.currentLanguage == 'ar';
    final TextEditingController inputController = TextEditingController();
    final isEmail = method == 'email';

    String selectedCountryCode = '962';
    String selectedCountryFlag = '🇯🇴';

    showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setStateDialog) {
            return Directionality(
              textDirection: isArabic ? TextDirection.rtl : TextDirection.ltr,
              child: AlertDialog(
                backgroundColor: const Color(0xFF1E1E1E),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                title: Text(
                  isArabic ? "إعادة تعيين كلمة المرور" : "Reset Password",
                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                ),
                content: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      isArabic
                          ? (isEmail ? "أدخل بريدك الإلكتروني لتلقي الرمز المكون من 6 أرقام." : "أدخل رقم هاتفك لتلقي الرمز المكون من 6 أرقام.")
                          : (isEmail ? "Enter your email to receive a 6-digit code." : "Enter your phone number to receive a 6-digit code."),
                      style: const TextStyle(color: Colors.white70),
                    ),
                    const SizedBox(height: 16),
                    TextField(
                      controller: inputController,
                      style: const TextStyle(color: Colors.white),
                      keyboardType: isEmail ? TextInputType.emailAddress : TextInputType.phone,
                      decoration: InputDecoration(
                        labelText: isEmail ? (isArabic ? "البريد الإلكتروني" : "Email") : (isArabic ? "رقم الهاتف" : "Phone Number"),
                        labelStyle: const TextStyle(color: Colors.white54),
                        
                        // --- DYNAMIC GLOBAL PREFIX ---
                        prefixIcon: isEmail
                            ? const Icon(Icons.email, color: Colors.white54)
                            : InkWell(
                                onTap: () {
                                  showCountryPicker(
                                    context: context,
                                    showPhoneCode: true,
                                    countryListTheme: const CountryListThemeData(
                                      backgroundColor: Color(0xFF1E1E1E),
                                      textStyle: TextStyle(color: Colors.white),
                                      searchTextStyle: TextStyle(color: Colors.white),
                                    ),
                                    onSelect: (Country country) {
                                      setStateDialog(() {
                                        selectedCountryFlag = country.flagEmoji;
                                        selectedCountryCode = country.phoneCode;
                                      });
                                    },
                                  );
                                },
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    const SizedBox(width: 12),
                                    Text(
                                      '$selectedCountryFlag +$selectedCountryCode',
                                      style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
                                    ),
                                    const SizedBox(width: 4),
                                    const Icon(Icons.arrow_drop_down, color: Color(0xFFFFD700)),
                                    const SizedBox(width: 8),
                                    Container(width: 1, height: 24, color: Colors.white38),
                                    const SizedBox(width: 12),
                                  ],
                                ),
                              ),
                        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: Colors.white38)),
                        focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: Color(0xFFFFD700))),
                      ),
                    ),
                  ],
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: Text(isArabic ? "إلغاء" : "Cancel", style: const TextStyle(color: Colors.white54)),
                  ),
                  ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFFFFD700),
                      foregroundColor: Colors.black,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    ),
                    onPressed: () {
                      if (inputController.text.isEmpty) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text(isArabic ? "❌ يرجى إدخال البيانات المطلوبة!" : "❌ Please enter the required information!"),
                            backgroundColor: Colors.red,
                            behavior: SnackBarBehavior.floating,
                          ),
                        );
                        return;
                      }
                      Navigator.pop(context);
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(isArabic ? "✅ تم إرسال الرمز بنجاح!" : "✅ Code sent successfully!"),
                          backgroundColor: Colors.green,
                          behavior: SnackBarBehavior.floating,
                        ),
                      );
                    },
                    child: Text(isArabic ? "إرسال" : "Send", style: const TextStyle(fontWeight: FontWeight.bold)),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  // ==========================================
  // BUILD METHOD (UI)
  // ==========================================
  @override
  Widget build(BuildContext context) {
    final isArabic = _language == 'ar';

    return Scaffold(
      backgroundColor: const Color(0xFF121212),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24.0),
          child: Directionality(
            textDirection: isArabic ? TextDirection.rtl : TextDirection.ltr,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                // --- LANGUAGE BUTTON ---
                Align(
                  alignment: isArabic ? Alignment.topLeft : Alignment.topRight,
                  child: TextButton.icon(
                    onPressed: _toggleLanguage,
                    icon: const Icon(Icons.language, color: Colors.white70),
                    label: Text(
                      isArabic ? 'English' : 'عربي',
                      style: const TextStyle(color: Colors.white70, fontWeight: FontWeight.bold, fontSize: 16),
                    ),
                  ),
                ),
                const SizedBox(height: 20),

                // --- LOGO & TITLE ---
                const Icon(Icons.location_on, size: 80, color: Color(0xFFFFD700)),
                const SizedBox(height: 16),
                const Text(
                  "Rased | راصد",
                  style: TextStyle(color: Colors.white, fontSize: 32, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 40),

                // --- LOGIN CARD ---
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
                          
                          // National ID Field
                          TextField(
                            controller: _emailController,
                            style: const TextStyle(color: Colors.white),
                            keyboardType: TextInputType.number, 
                            inputFormatters: [
                              FilteringTextInputFormatter.digitsOnly,
                              LengthLimitingTextInputFormatter(10), 
                            ],
                            decoration: InputDecoration(
                              labelText: isArabic ? "الرقم الوطني" : "National ID",
                              labelStyle: const TextStyle(color: Colors.white54),
                              prefixIcon: const Icon(Icons.badge, color: Colors.white54),
                              enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.2)), borderRadius: BorderRadius.circular(10)),
                              focusedBorder: OutlineInputBorder(borderSide: const BorderSide(color: Color(0xFFFFD700)), borderRadius: BorderRadius.circular(10)),
                            ),
                          ),
                          const SizedBox(height: 20),

                          // Password Field
                          TextField(
                            controller: _passwordController,
                            obscureText: true,
                            style: const TextStyle(color: Colors.white),
                            decoration: InputDecoration(
                              labelText: isArabic ? "كلمة المرور" : "Password",
                              labelStyle: const TextStyle(color: Colors.white54),
                              prefixIcon: const Icon(Icons.lock, color: Colors.white54),
                              enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.2)), borderRadius: BorderRadius.circular(10)),
                              focusedBorder: OutlineInputBorder(borderSide: const BorderSide(color: Color(0xFFFFD700)), borderRadius: BorderRadius.circular(10)),
                            ),
                          ),

                          // Forgot Password Button
                          Align(
                            alignment: isArabic ? Alignment.centerLeft : Alignment.centerRight,
                            child: TextButton(
                              onPressed: _showForgotPasswordChoiceDialog,
                              child: Text(
                                isArabic ? "نسيت كلمة المرور؟" : "Forgot Password?",
                                style: const TextStyle(color: Color(0xFFFFD700), fontWeight: FontWeight.bold),
                              ),
                            ),
                          ),
                          const SizedBox(height: 16),

                          // Login Button
                          SizedBox(
                            width: double.infinity,
                            height: 50,
                            child: ElevatedButton(
                              onPressed: _isLoading ? null : _handleLogin,
                              style: ElevatedButton.styleFrom(
                                backgroundColor: const Color(0xFFFFD700),
                                foregroundColor: Colors.black,
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                              ),
                              child: _isLoading
                                  ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(color: Colors.black, strokeWidth: 2))
                                  : Text(
                                      isArabic ? "تسجيل الدخول" : "Log In",
                                      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                                    ),
                            ),
                          ),

                          // --- CREATE ACCOUNT LINK (With Auto-Fill Support) ---
                          Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Text(isArabic ? "ليس لديك حساب؟" : "Don't have an account?", style: const TextStyle(color: Colors.white70)),
                              TextButton(
                                onPressed: () async {
                                  // Wait for the Register screen to return the National ID
                                  final registeredId = await Navigator.push(
                                    context,
                                    MaterialPageRoute(builder: (context) => RegisterScreen(language: _language)),
                                  );
                                  
                                  // If the user registered successfully, auto-fill the login box!
                                  if (registeredId != null && registeredId is String) {
                                    setState(() {
                                      _emailController.text = registeredId;
                                      // Optional: You could also focus the password field here automatically
                                    });
                                  }
                                },
                                child: Text(
                                  isArabic ? "إنشاء حساب" : "Register",
                                  style: const TextStyle(color: Color(0xFFFFD700), fontWeight: FontWeight.bold),
                                ),
                              ),
                            ],
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