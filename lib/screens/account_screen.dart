import 'package:flutter/material.dart';
import '../services/api_service.dart';
import 'login_screen.dart';
import 'profile_details_screen.dart';

class AccountScreen extends StatefulWidget {
  final String language;
  final VoidCallback onLanguageChanged;

  const AccountScreen({
    super.key,
    required this.language,
    required this.onLanguageChanged,
  });

  @override
  State<AccountScreen> createState() => _AccountScreenState();
}

class _AccountScreenState extends State<AccountScreen> {
  bool _locationEnabled = true;
  bool _notificationsEnabled = true;

  void _handleLogout() {
    ApiService.logout();

    Navigator.pushAndRemoveUntil(
      context,
      MaterialPageRoute(builder: (context) => const LoginScreen()),
      (route) => false,
    );

    final isArabic = widget.language == 'ar';
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          isArabic ? 'تم تسجيل الخروج بنجاح!' : 'Successfully logged out!',
        ),
        backgroundColor: Colors.green,
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isArabic = widget.language == 'ar';
    final String name =
        ApiService.loggedInEmail?.split('@')[0] ??
        (isArabic ? "مستخدم" : "User");

    return Directionality(
      textDirection: isArabic ? TextDirection.rtl : TextDirection.ltr,
      child: Scaffold(
        backgroundColor: const Color(0xFF121212),
        appBar: AppBar(
          backgroundColor: const Color(0xFF121212),
          elevation: 0,
          title: Text(
            isArabic ? 'الحساب' : 'Account',
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.bold,
            ),
          ),
          centerTitle: false,
        ),
        body: ListView(
          padding: const EdgeInsets.all(16.0),
          children: [
            // --- 1. User Header ---
            InkWell(
              onTap: () {
                // Navigate to the new Profile Details Screen!
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => const ProfileDetailsScreen(),
                  ),
                );
              },
              borderRadius: BorderRadius.circular(16),
              child: Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.05),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Row(
                  children: [
                    const CircleAvatar(
                      radius: 30,
                      backgroundColor: Color(0xFFFFD700),
                      child: Icon(Icons.person, size: 35, color: Colors.black),
                    ),
                    const SizedBox(width: 16),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          name,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          isArabic
                              ? "الرقم الوطني: 1234567890"
                              : "ID: 1234567890",
                          style: const TextStyle(
                            color: Colors.white54,
                            fontSize: 14,
                          ),
                        ),
                      ],
                    ),
                    const Spacer(),
                    Icon(
                      isArabic ? Icons.chevron_left : Icons.chevron_right,
                      color: Colors.white54,
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 24),

            // --- 2. My Profile Section ---
            _buildSectionTitle(isArabic ? "الملف الشخصي" : "My Profile"),
            _buildCard([
              _buildTile(
                isArabic ? "تغيير كلمة المرور" : "Change Password",
                isArabic,
                onTap: () {},
              ),
            ]),
            const SizedBox(height: 24),

            // --- 3. Settings Section ---
            _buildSectionTitle(isArabic ? "الإعدادات" : "Settings"),
            _buildCard([
              _buildTile(
                isArabic ? "لغة التطبيق" : "App Language",
                isArabic,
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      isArabic ? "عربي" : "English",
                      style: const TextStyle(color: Color(0xFF64B5F6)),
                    ),
                    const SizedBox(width: 8),
                    Icon(
                      isArabic ? Icons.chevron_left : Icons.chevron_right,
                      color: Colors.white54,
                    ),
                  ],
                ),
                onTap: widget.onLanguageChanged,
              ),
              _buildDivider(),
              _buildSwitchTile(
                isArabic ? "الموقع" : "Location",
                _locationEnabled,
                (val) => setState(() => _locationEnabled = val),
              ),
              _buildDivider(),
              _buildSwitchTile(
                isArabic ? "الإشعارات" : "Notifications",
                _notificationsEnabled,
                (val) => setState(() => _notificationsEnabled = val),
              ),
            ]),
            const SizedBox(height: 24),

            // --- 4. Help & Support Section ---
            _buildSectionTitle(isArabic ? "المساعدة والدعم" : "Help & Support"),
            _buildCard([
              _buildTile(
                isArabic ? "المساعدة" : "Help",
                isArabic,
                onTap: () {},
              ),
              _buildDivider(),
              _buildTile(
                isArabic ? "سياسة الخصوصية" : "Privacy Policy",
                isArabic,
                onTap: () {},
              ),
              _buildDivider(),
              _buildTile(
                isArabic ? "مشاركة تطبيق راصد" : "Share Rased App",
                isArabic,
                onTap: () {},
              ),
              _buildDivider(),
              _buildTile(
                isArabic ? "الاقتراحات والشكاوى" : "Suggestions & Complaints",
                isArabic,
                onTap: () {},
              ),
              _buildDivider(),
              _buildTile(
                isArabic ? "قيّم تجربتك" : "Rate Your Experience",
                isArabic,
                onTap: () {},
              ),
            ]),
            const SizedBox(height: 24),

            // --- 5. Logout Section ---
            _buildCard([
              ListTile(
                leading: const Icon(Icons.logout, color: Colors.redAccent),
                title: Text(
                  isArabic ? "تسجيل الخروج" : "Logout",
                  style: const TextStyle(
                    color: Colors.redAccent,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                onTap: _handleLogout,
              ),
            ]),
            const SizedBox(height: 120),
          ],
        ),
      ),
    );
  }

  // ==========================================
  // HELPER WIDGETS
  // ==========================================

  Widget _buildSectionTitle(String title) {
    return Padding(
      padding: const EdgeInsets.only(left: 8, right: 8, bottom: 12),
      child: Text(
        title,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 18,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }

  Widget _buildCard(List<Widget> children) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(children: children),
    );
  }

  Widget _buildTile(
    String title,
    bool isArabic, {
    Widget? trailing,
    VoidCallback? onTap,
  }) {
    return ListTile(
      title: Text(title, style: const TextStyle(color: Colors.white)),
      trailing:
          trailing ??
          Icon(
            isArabic ? Icons.chevron_left : Icons.chevron_right,
            color: Colors.white54,
          ),
      onTap: onTap,
    );
  }

  Widget _buildSwitchTile(
    String title,
    bool value,
    ValueChanged<bool> onChanged,
  ) {
    return SwitchListTile(
      title: Text(title, style: const TextStyle(color: Colors.white)),
      value: value,
      onChanged: onChanged,
      activeThumbColor: Colors.black,
      activeTrackColor: const Color(0xFFFFD700),
      inactiveTrackColor: Colors.white12,
    );
  }

  Widget _buildDivider() {
    return const Divider(
      height: 1,
      color: Colors.white12,
      indent: 16,
      endIndent: 16,
    );
  }
}
