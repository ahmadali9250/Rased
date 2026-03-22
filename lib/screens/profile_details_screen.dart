import 'package:flutter/material.dart';
import '../services/api_service.dart';

class ProfileDetailsScreen extends StatefulWidget {
  const ProfileDetailsScreen({super.key});

  @override
  State<ProfileDetailsScreen> createState() => _ProfileDetailsScreenState();
}

class _ProfileDetailsScreenState extends State<ProfileDetailsScreen> {
  late TextEditingController _phoneController;
  late TextEditingController _emailController;

  @override
  void initState() {
    super.initState();
    _phoneController = TextEditingController(text: "0791234567");
    _emailController = TextEditingController(
      text: ApiService.loggedInEmail ?? "",
    );
  }

  @override
  void dispose() {
    _phoneController.dispose();
    _emailController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isArabic = ApiService.currentLanguage == 'ar';

    return Directionality(
      textDirection: isArabic ? TextDirection.rtl : TextDirection.ltr,
      child: Scaffold(
        backgroundColor: const Color(0xFF121212),
        appBar: AppBar(
          backgroundColor: const Color(0xFF121212),
          elevation: 0,
          title: Text(
            isArabic ? 'تفاصيل الحساب' : 'Profile Details',
            style: const TextStyle(color: Colors.white),
          ),
          iconTheme: const IconThemeData(color: Colors.white),
        ),
        body: ListView(
          padding: const EdgeInsets.all(24.0),
          children: [
            // 1. Profile Picture (Locked with a badge)
            Center(
              child: Stack(
                alignment: Alignment.bottomRight,
                children: [
                  const CircleAvatar(
                    radius: 50,
                    backgroundColor: Color(0xFFFFD700),
                    child: Icon(Icons.person, size: 60, color: Colors.black),
                  ),
                  Container(
                    padding: const EdgeInsets.all(4),
                    decoration: const BoxDecoration(
                      color: Colors.black,
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.verified_user,
                      color: Colors.green,
                      size: 24,
                    ), // Official badge!
                  ),
                ],
              ),
            ),
            const SizedBox(height: 32),

            // 2. Full Name (Locked)
            _buildLockedField(
              label: isArabic ? "الاسم الكامل" : "Full Name",
              value: "Ahmad Al-Sayyed", // Just a placeholder for now
            ),
            const SizedBox(height: 16),

            // 3. ID Number (Locked)
            _buildLockedField(
              label: isArabic ? "الرقم الوطني" : "ID Number",
              value: "1234567890",
            ),
            const SizedBox(height: 16),

            // 4. Date of Birth (Locked)
            _buildLockedField(
              label: isArabic ? "تاريخ الميلاد" : "Date of Birth",
              value: "15/08/1998",
            ),
            const SizedBox(height: 16),

            // 5. Phone Number (Editable)
            _buildEditableField(
              label: isArabic ? "رقم الهاتف" : "Phone Number",
              controller: _phoneController,
              icon: Icons.phone,
            ),
            const SizedBox(height: 16),

            // 6. Email (Editable)
            _buildEditableField(
              label: isArabic ? "البريد الإلكتروني" : "Email",
              controller: _emailController,
              icon: Icons.email,
            ),
            const SizedBox(height: 40),

            // 7. Delete Account Button
            OutlinedButton.icon(
              onPressed: () {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(
                      isArabic
                          ? 'زر الحذف غير متصل بقاعدة البيانات بعد!'
                          : 'Delete not wired to database yet!',
                    ),
                    backgroundColor: Colors.red,
                  ),
                );
              },
              icon: const Icon(Icons.delete_forever, color: Colors.redAccent),
              label: Text(
                isArabic ? "حذف الحساب" : "Delete Account",
                style: const TextStyle(
                  color: Colors.redAccent,
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                ),
              ),
              style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 16),
                side: const BorderSide(color: Colors.redAccent),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
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
        Text(
          label,
          style: const TextStyle(color: Colors.white54, fontSize: 14),
        ),
        const SizedBox(height: 8),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.05),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.white12),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                value,
                style: const TextStyle(color: Colors.white54, fontSize: 16),
              ),
              const Icon(Icons.lock_outline, color: Colors.white24, size: 20),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildEditableField({
    required String label,
    required TextEditingController controller,
    required IconData icon,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(color: Colors.white70, fontSize: 14),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: controller,
          style: const TextStyle(color: Colors.white, fontSize: 16),
          decoration: InputDecoration(
            prefixIcon: Icon(icon, color: Colors.white54),
            suffixIcon: const Icon(
              Icons.edit,
              color: Color(0xFFFFD700),
              size: 20,
            ),
            filled: true,
            fillColor: Colors.transparent,
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: const BorderSide(color: Colors.white38),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: const BorderSide(color: Color(0xFFFFD700)),
            ),
          ),
        ),
      ],
    );
  }
}
