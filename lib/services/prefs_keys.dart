/// Every SharedPreferences key the app writes, in one place.
///
/// The onboarding flag was once written under two different names, which
/// made the app show onboarding (and then the login screen) on every cold
/// start even with a valid saved token. Keep new keys here.
abstract final class PrefsKeys {
  static const String token = 'token';
  static const String email = 'email';
  static const String role = 'role';
  static const String userName = 'userName';
  static const String userPhone = 'userPhone';
  static const String userEmail = 'userEmail';
  static const String userRole = 'userRole';

  /// Canonical onboarding flag.
  static const String hasSeenOnboarding = 'hasSeenOnboarding';

  /// Written by older builds; read as a fallback so those devices do not
  /// see onboarding again.
  static const String legacyHasSeenOnboarding = 'has_seen_onboarding';

  /// 'ar' or 'en'. Absent until the user switches language once.
  static const String language = 'language';

  /// Offline report queue (see `OfflineQueue`).
  static const String pendingReports = 'pending_reports';

  /// Live-camera test mode: detect and confirm, but never upload.
  static const String dryRunMode = 'dry_run_mode';

  /// Removed on logout. Everything else (onboarding flag, language, offline
  /// queue) survives a logout on purpose.
  static const List<String> authKeys = <String>[
    token,
    email,
    role,
    userName,
    userPhone,
    userEmail,
    userRole,
  ];
}
