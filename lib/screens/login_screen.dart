import 'dart:ui';
import 'package:flutter/material.dart';
import 'map_screen.dart';
import '../services/api_service.dart';
import 'package:country_picker/country_picker.dart';
import 'register_screen.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final TextEditingController _emailController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  bool _isLoading = false;

  late String _language = ApiService.currentLanguage;

  void _toggleLanguage() {
    setState(() {
      _language = _language == 'en' ? 'ar' : 'en';
      ApiService.currentLanguage = _language;
    });
  }

  void _handleLogin() async {
    final isArabic = _language == 'ar';

    // 1. Block empty boxes!
    if (_emailController.text.isEmpty || _passwordController.text.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            isArabic
                ? 'الرجاء إدخال البريد الإلكتروني وكلمة المرور'
                : 'Please enter an email and password',
          ),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    setState(() => _isLoading = true);

    // 2. Actually ask the database if the password is correct!
    bool success = await ApiService.login(
      _emailController.text.trim(),
      _passwordController.text.trim(),
    );

    if (!mounted) return;
    setState(() => _isLoading = false);

    // 3. ONLY let them in if the database said "true"
    if (success) {
      ApiService.currentLanguage = _language; // Save language globally

      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (context) => const MapScreen()),
      );
    } else {
      // 4. Show the translated error message!
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            isArabic
                ? '❌ البريد الإلكتروني أو كلمة المرور غير صحيحة!'
                : '❌ Invalid email or password!',
          ),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  // --- FORGOT PASSWORD DIALOG ---
  // ==========================================
  // 1. CHOOSE RESET METHOD DIALOG
  // ==========================================
  void _showForgotPasswordChoiceDialog() {
    final isArabic = ApiService.currentLanguage == 'ar';

    showDialog(
      context: context,
      builder: (context) {
        return Directionality(
          textDirection: isArabic ? TextDirection.rtl : TextDirection.ltr,
          child: AlertDialog(
            backgroundColor: const Color(0xFF1E1E1E),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
            title: Text(
              isArabic ? "طريقة استعادة كلمة المرور" : "Reset Password Method",
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
              ),
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Option 1: Email
                ListTile(
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  tileColor: Colors.white.withValues(alpha: 0.05),
                  leading: const Icon(Icons.email, color: Color(0xFFFFD700)),
                  title: Text(
                    isArabic ? "البريد الإلكتروني" : "Email",
                    style: const TextStyle(color: Colors.white),
                  ),
                  onTap: () {
                    Navigator.pop(context);
                    _showResetInputDialog("email");
                  },
                ),
                const SizedBox(height: 12),
                // Option 2: SMS
                ListTile(
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  tileColor: Colors.white.withValues(alpha: 0.05),
                  leading: const Icon(Icons.sms, color: Color(0xFFFFD700)),
                  title: Text(
                    isArabic ? "رسالة نصية (SMS)" : "SMS",
                    style: const TextStyle(color: Colors.white),
                  ),
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
                child: Text(
                  isArabic ? "إلغاء" : "Cancel",
                  style: const TextStyle(color: Colors.white54),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  // ==========================================
  // 2. ENTER EMAIL OR PHONE DIALOG (With Dropdown)
  // ==========================================
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
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
                title: Text(
                  isArabic ? "إعادة تعيين كلمة المرور" : "Reset Password",
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                content: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      isArabic
                          ? (isEmail
                                ? "أدخل بريدك الإلكتروني لتلقي الرمز المكون من 6 أرقام."
                                : "أدخل رقم هاتفك لتلقي الرمز المكون من 6 أرقام.")
                          : (isEmail
                                ? "Enter your email to receive a 6-digit code."
                                : "Enter your phone number to receive a 6-digit code."),
                      style: const TextStyle(color: Colors.white70),
                    ),
                    const SizedBox(height: 16),
                    TextField(
                      controller: inputController,
                      style: const TextStyle(color: Colors.white),
                      keyboardType: isEmail
                          ? TextInputType.emailAddress
                          : TextInputType.phone,
                      decoration: InputDecoration(
                        labelText: isEmail
                            ? (isArabic ? "البريد الإلكتروني" : "Email")
                            : (isArabic ? "رقم الهاتف" : "Phone Number"),
                        labelStyle: const TextStyle(color: Colors.white54),
                        // --- DYNAMIC GLOBAL PREFIX ---
                        prefixIcon: isEmail
                            ? const Icon(Icons.email, color: Colors.white54)
                            : InkWell(
                                onTap: () {
                                  showCountryPicker(
                                    context: context,
                                    showPhoneCode: true,
                                    countryListTheme:
                                        const CountryListThemeData(
                                          backgroundColor: Color(0xFF1E1E1E),
                                          textStyle: TextStyle(
                                            color: Colors.white,
                                          ),
                                          searchTextStyle: TextStyle(
                                            color: Colors.white,
                                          ),
                                        ),
                                    onSelect: (Country country) {
                                      setStateDialog(() {
                                        // Updates just the dialog!
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
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 16,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                    const SizedBox(width: 4),
                                    const Icon(
                                      Icons.arrow_drop_down,
                                      color: Color(0xFFFFD700),
                                    ),
                                    const SizedBox(width: 8),
                                    Container(
                                      width: 1,
                                      height: 24,
                                      color: Colors.white38,
                                    ),
                                    const SizedBox(width: 12),
                                  ],
                                ),
                              ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: const BorderSide(color: Colors.white38),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: const BorderSide(
                            color: Color(0xFFFFD700),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: Text(
                      isArabic ? "إلغاء" : "Cancel",
                      style: const TextStyle(color: Colors.white54),
                    ),
                  ),
                  ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFFFFD700),
                      foregroundColor: Colors.black,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                    onPressed: () {
                      if (inputController.text.isEmpty) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text(
                              isArabic
                                  ? "❌ يرجى إدخال البيانات المطلوبة!"
                                  : "❌ Please enter the required information!",
                            ),
                            backgroundColor: Colors.red,
                          ),
                        );
                        return;
                      }
                      Navigator.pop(context);
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(
                            isArabic
                                ? "✅ تم إرسال الرمز بنجاح!"
                                : "✅ Code sent successfully!",
                          ),
                          backgroundColor: Colors.green,
                        ),
                      );
                    },
                    child: Text(
                      isArabic ? "إرسال" : "Send",
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

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
                      style: const TextStyle(
                        color: Colors.white70,
                        fontWeight: FontWeight.bold,
                        fontSize: 16,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 20),

                // Logo
                const Icon(
                  Icons.location_on,
                  size: 80,
                  color: Color(0xFFFFD700),
                ),
                const SizedBox(height: 16),
                const Text(
                  "Rased | راصد",
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 32,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 40),

                // Login Card
                ClipRRect(
                  borderRadius: BorderRadius.circular(20),
                  child: BackdropFilter(
                    filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
                    child: Container(
                      padding: const EdgeInsets.all(24),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.05),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(
                          color: Colors.white.withValues(alpha: 0.1),
                        ),
                      ),
                      child: Column(
                        children: [
                          // Email Field
                          TextField(
                            controller: _emailController,
                            style: const TextStyle(color: Colors.white),
                            decoration: InputDecoration(
                              labelText: isArabic
                                  ? "البريد الإلكتروني"
                                  : "Email",
                              labelStyle: const TextStyle(
                                color: Colors.white54,
                              ),
                              prefixIcon: const Icon(
                                Icons.email,
                                color: Colors.white54,
                              ),
                              enabledBorder: OutlineInputBorder(
                                borderSide: BorderSide(
                                  color: Colors.white.withValues(alpha: 0.2),
                                ),
                                borderRadius: BorderRadius.circular(10),
                              ),
                              focusedBorder: OutlineInputBorder(
                                borderSide: const BorderSide(
                                  color: Color(0xFFFFD700),
                                ),
                                borderRadius: BorderRadius.circular(10),
                              ),
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
                              labelStyle: const TextStyle(
                                color: Colors.white54,
                              ),
                              prefixIcon: const Icon(
                                Icons.lock,
                                color: Colors.white54,
                              ),
                              enabledBorder: OutlineInputBorder(
                                borderSide: BorderSide(
                                  color: Colors.white.withValues(alpha: 0.2),
                                ),
                                borderRadius: BorderRadius.circular(10),
                              ),
                              focusedBorder: OutlineInputBorder(
                                borderSide: const BorderSide(
                                  color: Color(0xFFFFD700),
                                ),
                                borderRadius: BorderRadius.circular(10),
                              ),
                            ),
                          ),

                          // --- FORGOT PASSWORD BUTTON ---
                          Align(
                            alignment: isArabic
                                ? Alignment.centerLeft
                                : Alignment.centerRight,
                            child: TextButton(
                              onPressed: _showForgotPasswordChoiceDialog,
                              child: Text(
                                isArabic
                                    ? "نسيت كلمة المرور؟"
                                    : "Forgot Password?",
                                style: const TextStyle(
                                  color: Color(0xFFFFD700),
                                  fontWeight: FontWeight.bold,
                                ),
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
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(10),
                                ),
                              ),
                              child: _isLoading
                                  ? const SizedBox(
                                      height: 20,
                                      width: 20,
                                      child: CircularProgressIndicator(
                                        color: Colors.black,
                                        strokeWidth: 2,
                                      ),
                                    )
                                  : Text(
                                      isArabic ? "تسجيل الدخول" : "Log In",
                                      style: const TextStyle(
                                        fontSize: 16,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                            ),
                          ),

                          // --- NEW: CREATE ACCOUNT LINK ---
                          Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Text(
                                isArabic ? "ليس لديك حساب؟" : "Don't have an account?",
                                style: const TextStyle(color: Colors.white70),
                              ),
                              TextButton(
                                onPressed: () {
                                  Navigator.push(
                                    context,
                                    MaterialPageRoute(
                                      builder: (context) => RegisterScreen(language: _language),
                                    ),
                                  );
                                },
                                child: Text(
                                  isArabic ? "إنشاء حساب" : "Register",
                                  style: const TextStyle(
                                    color: Color(0xFFFFD700),
                                    fontWeight: FontWeight.bold,
                                  ),
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
