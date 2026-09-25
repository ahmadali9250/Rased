import 'package:flutter/foundation.dart';

/// Signals that the set of hazards on the server changed.
///
/// Bumped after a report is created (manual form or live camera, both go
/// through `ApiService.submitReport`) and after an admin status change.
/// The map, My Reports and the admin dashboard listen and refetch, so a new
/// report shows up without leaving the app or logging in again.
abstract final class ReportEvents {
  static final ValueNotifier<int> version = ValueNotifier<int>(0);

  static void bump() => version.value = version.value + 1;
}
