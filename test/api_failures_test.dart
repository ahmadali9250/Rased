import 'package:flutter_test/flutter_test.dart';
import 'package:tareeqi/services/api_service.dart';

void main() {
  test('every AuthFailure kind has text in both languages', () {
    for (final kind in AuthFailureKind.values) {
      final f = AuthFailure(kind, status: 500, serverMessage: 'srv');
      expect(f.message(true), isNotEmpty, reason: '$kind ar');
      expect(f.message(false), isNotEmpty, reason: '$kind en');
    }
  });

  test('every ReportFailure kind has text in both languages', () {
    for (final kind in ReportFailureKind.values) {
      final f = ReportFailure(kind, status: 500, serverMessage: 'srv');
      expect(f.message(true), isNotEmpty, reason: '$kind ar');
      expect(f.message(false), isNotEmpty, reason: '$kind en');
    }
  });

  test('server messages are shown as-is, with a fallback when blank', () {
    const withText = AuthFailure(AuthFailureKind.server, serverMessage: 'Bad');
    expect(withText.message(true), 'Bad');
    const blank = AuthFailure(AuthFailureKind.server, serverMessage: '  ');
    expect(blank.message(false), isNot(contains('  ')));
    expect(blank.message(false), isNotEmpty);
  });

  test('http failures include the status code', () {
    const f = ReportFailure(ReportFailureKind.http, status: 503);
    expect(f.message(false), contains('503'));
    expect(f.message(true), contains('503'));
  });

  test('Arabic and English texts differ', () {
    const f = ReportFailure(ReportFailureKind.network);
    expect(f.message(true), isNot(f.message(false)));
  });
}
