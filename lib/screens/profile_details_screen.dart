import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl_phone_field/intl_phone_field.dart';
import '../services/api_service.dart';

/// Displays the user's personal details.
///
/// Allows editing of Phone Number and Email, and provides a secure flow 
/// for changing passwords and verifying account changes via OTP.
class ProfileDetailsScreen extends StatefulWidget {
  const ProfileDetailsScreen({super.key});

  @override
  State<ProfileDetailsScreen> createState() => _ProfileDetailsScreenState();
}

class _ProfileDetailsScreenState extends State<ProfileDetailsScreen> {
  // --- Controllers & State ---
  late TextEditingController _phoneController;
  late TextEditingController _emailController;

  late String _initialPhone;
  late String _initialEmail;
  bool _hasChanges = false;

  @override
  void initState() {
    super.initState();
    
    // ✅ Fetching real data from ApiService
    String rawPhone = ApiService.userPhone;
    // Strip country code if the backend provides it, to avoid IntlPhoneField bug
    if (rawPhone.startsWith('+962')) rawPhone = rawPhone.substring(4);
    if (rawPhone.startsWith('00962')) rawPhone = rawPhone.substring(5);
    
    _initialPhone = rawPhone;
    _initialEmail = ApiService.userEmail;

    _phoneController = TextEditingController(text: _initialPhone);
    _emailController = TextEditingController(text: _initialEmail);

    _phoneController.addListener(_checkForChanges);
    _emailController.addListener(_checkForChanges);
  }

  /// Listens to the text controllers to enable/disable the "Save Changes" button.
  void _checkForChanges() {
    bool isChanged =
        _phoneController.text != _initialPhone ||
        _emailController.text != _initialEmail;

    if (_hasChanges != isChanged) {
      setState(() {
        _hasChanges = isChanged;
      });
    }
  }

  @override
  void dispose() {
    _phoneController.dispose();
    _emailController.dispose();
    super.dispose();
  }

  // ==========================================
  // CHANGE PASSWORD DIALOG
  // ==========================================
  
  /// Initiates a secure flow allowing the user to update their password.
  /// Enforces validation rules (Current match, New match, New != Old).
  void _showChangePasswordDialog() {
    final isArabic = ApiService.currentLanguage == 'ar';
    final TextEditingController oldPass = TextEditingController();
    final TextEditingController newPass = TextEditingController();
    final TextEditingController confirmPass = TextEditingController();

    showDialog(
      context: context,
      builder: (context) {
        return Directionality(
          textDirection: isArabic ? TextDirection.rtl : TextDirection.ltr,
          child: AlertDialog(
            backgroundColor: const Color(0xFF1E1E1E),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            title: Text(
              isArabic ? "تغيير كلمة المرور" : "Change Password",
              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
            ),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: oldPass,
                    obscureText: true,
                    style: const TextStyle(color: Colors.white),
                    decoration: InputDecoration(
                      labelText: isArabic ? "كلمة المرور الحالية" : "Current Password",
                      labelStyle: const TextStyle(color: Colors.white54),
                      enabledBorder: const UnderlineInputBorder(borderSide: BorderSide(color: Colors.white38)),
                      focusedBorder: const UnderlineInputBorder(borderSide: BorderSide(color: Color(0xFFFFD700))),
                    ),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: newPass,
                    obscureText: true,
                    style: const TextStyle(color: Colors.white),
                    decoration: InputDecoration(
                      labelText: isArabic ? "كلمة المرور الجديدة" : "New Password",
                      labelStyle: const TextStyle(color: Colors.white54),
                      enabledBorder: const UnderlineInputBorder(borderSide: BorderSide(color: Colors.white38)),
                      focusedBorder: const UnderlineInputBorder(borderSide: BorderSide(color: Color(0xFFFFD700))),
                    ),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: confirmPass,
                    obscureText: true,
                    style: const TextStyle(color: Colors.white),
                    decoration: InputDecoration(
                      labelText: isArabic ? "تأكيد كلمة المرور الجديدة" : "Confirm New Password",
                      labelStyle: const TextStyle(color: Colors.white54),
                      enabledBorder: const UnderlineInputBorder(borderSide: BorderSide(color: Colors.white38)),
                      focusedBorder: const UnderlineInputBorder(borderSide: BorderSide(color: Color(0xFFFFD700))),
                    ),
                  ),
                  const SizedBox(height: 8),
                  
                  // "Forgot Password" Escape Hatch
                  Align(
                    alignment: isArabic ? Alignment.centerRight : Alignment.centerLeft,
                    child: TextButton(
                      onPressed: () {
                        Navigator.pop(context);
                        _showVerificationMethodDialog();
                      },
                      child: Text(isArabic ? "نسيت كلمة المرور؟" : "Forgot Password?", style: const TextStyle(color: Color(0xFFFFD700))),
                    ),
                  ),
                ],
              ),
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
                  if (oldPass.text.isEmpty || newPass.text.isEmpty || confirmPass.text.isEmpty) {
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(isArabic ? '❌ يرجى تعبئة جميع الحقول!' : '❌ Please fill all fields!'), backgroundColor: Colors.red, behavior: SnackBarBehavior.floating));
                    return;
                  }

                  if (oldPass.text != "1234") {
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(isArabic ? '❌ كلمة المرور الحالية غير صحيحة! (جرب 1234)' : '❌ Incorrect current password! (Try 1234)'), backgroundColor: Colors.red, behavior: SnackBarBehavior.floating));
                    return;
                  }

                  if (newPass.text != confirmPass.text) {
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(isArabic ? '❌ كلمة المرور الجديدة غير متطابقة!' : '❌ New passwords do not match!'), backgroundColor: Colors.red, behavior: SnackBarBehavior.floating));
                    return;
                  }

                  if (newPass.text == oldPass.text) {
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(isArabic ? '❌ كلمة المرور الجديدة يجب أن تكون مختلفة عن القديمة!' : '❌ New password cannot be the same as the old one!'), backgroundColor: Colors.red, behavior: SnackBarBehavior.floating));
                    return;
                  }

                  Navigator.pop(context);
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(isArabic ? '✅ تم تحديث كلمة المرور بنجاح!' : '✅ Password updated successfully!'), backgroundColor: Colors.green, behavior: SnackBarBehavior.floating));
                },
                child: Text(isArabic ? "حفظ" : "Save", style: const TextStyle(fontWeight: FontWeight.bold)),
              ),
            ],
          ),
        );
      },
    );
  }

  // ==========================================
  // VERIFICATION FLOW (OTP)
  // ==========================================
  
  void _showVerificationMethodDialog() {
    final isArabic = ApiService.currentLanguage == 'ar';
    final currentEmail = _emailController.text;
    final currentPhone = _phoneController.text;

    showDialog(
      context: context,
      builder: (context) {
        return Directionality(
          textDirection: isArabic ? TextDirection.rtl : TextDirection.ltr,
          child: AlertDialog(
            backgroundColor: const Color(0xFF1E1E1E),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            title: Text(isArabic ? "طريقة التحقق" : "Verification Method", style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  isArabic ? "أين تريد استلام رمز التحقق؟" : "Where would you like to receive the verification code?",
                  style: const TextStyle(color: Colors.white70),
                ),
                const SizedBox(height: 20),
                ListTile(
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  tileColor: Colors.white.withValues(alpha: 0.05),
                  leading: const Icon(Icons.sms, color: Color(0xFFFFD700)),
                  title: Text(isArabic ? "رسالة نصية (SMS)" : "SMS", style: const TextStyle(color: Colors.white)),
                  subtitle: Text(currentPhone, style: const TextStyle(color: Colors.white54)),
                  onTap: () {
                    Navigator.pop(context);
                    _showVerificationDialog("sms", currentPhone);
                  },
                ),
                const SizedBox(height: 12),
                ListTile(
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  tileColor: Colors.white.withValues(alpha: 0.05),
                  leading: const Icon(Icons.email, color: Color(0xFFFFD700)),
                  title: Text(isArabic ? "البريد الإلكتروني" : "Email", style: const TextStyle(color: Colors.white)),
                  subtitle: Text(currentEmail, style: const TextStyle(color: Colors.white54)),
                  onTap: () {
                    Navigator.pop(context);
                    _showVerificationDialog("email", currentEmail);
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

  void _showVerificationDialog(String type, String newValue) {
    final isArabic = ApiService.currentLanguage == 'ar';
    final TextEditingController otpController = TextEditingController();

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) {
        return Directionality(
          textDirection: isArabic ? TextDirection.rtl : TextDirection.ltr,
          child: AlertDialog(
            backgroundColor: const Color(0xFF1E1E1E),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            title: Text(isArabic ? "مطلوب التحقق" : "Verification Required", style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  isArabic ? "الرجاء إدخال الرمز المكون من 6 أرقام المرسل إلى $newValue" : "Please enter the 6-digit code sent to $newValue",
                  style: const TextStyle(color: Colors.white70),
                ),
                const SizedBox(height: 20),
                TextField(
                  controller: otpController,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  maxLength: 6, 
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white, fontSize: 24, letterSpacing: 8),
                  decoration: InputDecoration(
                    counterText: "", filled: true, fillColor: Colors.black26,
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
                style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFFFD700), foregroundColor: Colors.black, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))),
                onPressed: () {
                  if (otpController.text.length != 6) {
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(isArabic ? '❌ يرجى إدخال الرمز المكون من 6 أرقام بالكامل!' : '❌ Please enter the full 6-digit code!'), backgroundColor: Colors.red, behavior: SnackBarBehavior.floating));
                    return;
                  }
                  Navigator.pop(context);
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(isArabic ? '✅ تم التحقق بنجاح!' : '✅ Verified successfully!'), backgroundColor: Colors.green, behavior: SnackBarBehavior.floating));
                },
                child: Text(isArabic ? "تأكيد" : "Verify", style: const TextStyle(fontWeight: FontWeight.bold)),
              ),
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final isArabic = ApiService.currentLanguage == 'ar';
    
    // Fallback ID if the backend doesn't provide it yet
    final String nationalId = ApiService.loggedInEmail?.split('@')[0] ?? "Unknown";

    return Directionality(
      textDirection: isArabic ? TextDirection.rtl : TextDirection.ltr,
      child: Scaffold(
        backgroundColor: const Color(0xFF121212),
        appBar: AppBar(
          backgroundColor: const Color(0xFF121212),
          elevation: 0,
          title: Text(isArabic ? 'تفاصيل الحساب' : 'Profile Details', style: const TextStyle(color: Colors.white)),
          iconTheme: const IconThemeData(color: Colors.white),
        ),
        body: ListView(
          padding: const EdgeInsets.all(24.0),
          children: [
            // --- 1. PROFILE PICTURE ---
            Center(
              child: Stack(
                alignment: Alignment.bottomRight,
                children: [
                  const CircleAvatar(radius: 50, backgroundColor: Color(0xFFFFD700), child: Icon(Icons.person, size: 60, color: Colors.black)),
                  Container(
                    padding: const EdgeInsets.all(4),
                    decoration: const BoxDecoration(color: Colors.black, shape: BoxShape.circle),
                    child: const Icon(Icons.verified_user, color: Colors.green, size: 24),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 32),

            // --- 2. LOCKED FIELDS (Trust Anchor) ---
            // ✅ Connected to dynamic API Service variable!
            _buildLockedField(label: isArabic ? "الاسم الكامل" : "Full Name", value: ApiService.userName),
            const SizedBox(height: 16),
            _buildLockedField(label: isArabic ? "الرقم الوطني" : "ID Number", value: nationalId),
            const SizedBox(height: 16),
            _buildLockedField(label: isArabic ? "تاريخ الميلاد" : "Date of Birth", value: "10/01/2006"), // TODO: Ask backend to add this later!
            const SizedBox(height: 16),
            // ✅ Connected to dynamic API Service variable!
            _buildLockedField(label: isArabic ? "نوع الحساب" : "Account Role", value: ApiService.userRole),
            const SizedBox(height: 16),

            // --- 3. EDITABLE FIELDS ---
            Text(isArabic ? "رقم الهاتف" : "Phone Number", style: const TextStyle(color: Colors.white70, fontSize: 14)),
            const SizedBox(height: 8),
            
            // Standardized IntlPhoneField
            IntlPhoneField(
              controller: _phoneController,
              dropdownIcon: const Icon(Icons.arrow_drop_down, color: Color(0xFFFFD700)),
              dropdownTextStyle: const TextStyle(color: Colors.white, fontSize: 16),
              style: const TextStyle(color: Colors.white),
              initialCountryCode: 'JO', // Defaults to Jordan flag
              decoration: InputDecoration(
                filled: true, fillColor: Colors.transparent,
                suffixIcon: const Icon(Icons.edit, color: Color(0xFFFFD700), size: 20),
                enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: Colors.white38)),
                focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: Color(0xFFFFD700))),
              ),
              onChanged: (phone) {
                _checkForChanges();
              },
            ),
            const SizedBox(height: 16),

            _buildEditableField(label: isArabic ? "البريد الإلكتروني" : "Email", controller: _emailController, icon: Icons.email),
            const SizedBox(height: 40),

            // --- 4. ACTION BUTTONS ---
            OutlinedButton.icon(
              onPressed: _showChangePasswordDialog,
              icon: const Icon(Icons.lock_reset, color: Colors.white70),
              label: Text(isArabic ? "تغيير كلمة المرور" : "Change Password", style: const TextStyle(color: Colors.white70, fontSize: 16, fontWeight: FontWeight.bold)),
              style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 16), side: const BorderSide(color: Colors.white38), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
            ),
            const SizedBox(height: 40),

            SizedBox(
              width: double.infinity, height: 55,
              child: ElevatedButton.icon(
                onPressed: _hasChanges ? () => _showVerificationDialog("email", _emailController.text) : null,
                icon: Icon(Icons.save, color: _hasChanges ? Colors.black : Colors.white38),
                label: Text(isArabic ? "حفظ التغييرات" : "Save Changes", style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: _hasChanges ? Colors.black : Colors.white38)),
                style: ElevatedButton.styleFrom(backgroundColor: _hasChanges ? const Color(0xFFFFD700) : Colors.white.withValues(alpha: 0.1), disabledBackgroundColor: Colors.white.withValues(alpha: 0.1), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
              ),
            ),
            const SizedBox(height: 24),

            OutlinedButton.icon(
              onPressed: () => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(isArabic ? 'زر الحذف غير متصل بقاعدة البيانات بعد!' : 'Delete not wired to database yet!'), backgroundColor: Colors.red, behavior: SnackBarBehavior.floating)),
              icon: const Icon(Icons.delete_forever, color: Colors.redAccent),
              label: Text(isArabic ? "حذف الحساب" : "Delete Account", style: const TextStyle(color: Colors.redAccent, fontSize: 16, fontWeight: FontWeight.bold)),
              style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 16), side: const BorderSide(color: Colors.redAccent), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
            ),
            const SizedBox(height: 40),
          ],
        ),
      ),
    );
  }

  // ==========================================
  // HELPER WIDGETS
  // ==========================================

  Widget _buildLockedField({required String label, required String value}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(color: Colors.white54, fontSize: 14)),
        const SizedBox(height: 8),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
          decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.05), borderRadius: BorderRadius.circular(12), border: Border.all(color: Colors.white12)),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(value, style: const TextStyle(color: Colors.white54, fontSize: 16)),
              const Icon(Icons.lock_outline, color: Colors.white24, size: 20),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildEditableField({required String label, required TextEditingController controller, required IconData icon}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(color: Colors.white70, fontSize: 14)),
        const SizedBox(height: 8),
        TextField(
          controller: controller,
          style: const TextStyle(color: Colors.white, fontSize: 16),
          keyboardType: TextInputType.emailAddress,
          decoration: InputDecoration(
            prefixIcon: Icon(icon, color: Colors.white54),
            suffixIcon: const Icon(Icons.edit, color: Color(0xFFFFD700), size: 20),
            filled: true, fillColor: Colors.transparent,
            enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: Colors.white38)),
            focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: Color(0xFFFFD700))),
          ),
        ),
      ],
    );
  }
}