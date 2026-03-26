import 'package:flutter/material.dart';
import '../services/api_service.dart';
import 'login_screen.dart';
import 'profile_details_screen.dart';
import 'admin_dashboard_screen.dart';

/// The Account & Settings screen for the Rased application.
///
/// Provides user profile access, app preferences (language, location, notifications),
/// help/support links, and access to the Admin Control Panel (if authorized).
class AccountScreen extends StatefulWidget {
  final String language;
  
  /// Callback to notify the parent MapScreen that the language has changed,
  /// triggering a full UI rebuild to swap between RTL/LTR.
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
  // Local state for toggle switches (To be connected to SharedPreferences later)
  bool _locationEnabled = true;
  bool _notificationsEnabled = true;

  /// Clears the user's session and navigates back to the Login Screen.
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
    
    // --- DYNAMIC USER DATA ---
    // Extracts the National ID from our synthetic email (e.g., 1234567890@rased.com)
    final String nationalId = ApiService.loggedInEmail?.split('@')[0] ?? "Unknown";
    final String displayName = isArabic ? "مواطن" : "Citizen";

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
            // ==========================================
            // 1. USER PROFILE HEADER
            // ==========================================
            InkWell(
              onTap: () {
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
                          displayName,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          isArabic
                              ? "الرقم الوطني: $nationalId"
                              : "ID: $nationalId",
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

            // ==========================================
            // 2. SETTINGS SECTION
            // ==========================================
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

            // ==========================================
            // 3. HELP & SUPPORT SECTION
            // ==========================================
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

            // ==========================================
            // 4. SYSTEM ACTIONS (ADMIN & LOGOUT)
            // ==========================================
            _buildCard([
              // 🔴 SECRET ADMIN BUTTON: Only shows if the user is an Admin or SuperAdmin
              if (ApiService.loggedInRole == 'Admin' || ApiService.loggedInRole == 'SuperAdmin') ...[
                ListTile(
                  leading: const Icon(Icons.admin_panel_settings, color: Color(0xFFFFD700)),
                  title: Text(
                    isArabic ? "لوحة التحكم" : "Control Panel",
                    style: const TextStyle(
                      color: Color(0xFFFFD700),
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  trailing: Icon(
                    isArabic ? Icons.chevron_left : Icons.chevron_right,
                    color: Colors.white54,
                  ),
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (context) => const AdminDashboardScreen(),
                      ),
                    );
                  },
                ),
                _buildDivider(),
              ],

              // 🔴 STANDARD LOGOUT BUTTON
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
            
            // Padding to ensure you can scroll past the floating bottom navigation bar
            const SizedBox(height: 120),
          ],
        ),
      ),
    );
  }

  // ==========================================
  // HELPER WIDGETS
  // ==========================================

  /// Builds the section headers (e.g., "Settings", "Help & Support")
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

  /// Wraps a list of UI elements in a beautifully rounded, translucent glassmorphism card.
  Widget _buildCard(List<Widget> children) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(children: children),
    );
  }

  /// Builds a standard clickable list item with an automatic RTL/LTR chevron arrow.
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

  /// Builds a list item containing a toggle switch for user preferences.
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

  /// A subtle internal divider to separate items within a card.
  Widget _buildDivider() {
    return const Divider(
      height: 1,
      color: Colors.white12,
      indent: 16,
      endIndent: 16,
    );
  }
}