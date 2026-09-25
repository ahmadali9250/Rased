import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:tareeqi/services/api_service.dart';
import 'package:tareeqi/utils/hazard_labels.dart';

Hazard _hazard({
  int typeId = 1,
  String? typeName,
  int statusId = 1,
  String? statusName,
}) {
  return Hazard(
    id: 'h1',
    location: const LatLng(31.95, 35.91),
    typeId: typeId,
    typeName: typeName,
    statusId: statusId,
    statusName: statusName,
    detectionCount: 1,
  );
}

void main() {
  group('status 4 reads the same everywhere', () {
    test('by id', () {
      expect(HazardLabels.statusById(4, false), 'Incorrect Report');
      expect(HazardLabels.statusById(4, true), 'بلاغ غير صحيح');
    });

    test('by server name, including the old "Rejected (AI)" wording', () {
      final h = _hazard(statusId: 4, statusName: 'Rejected (AI)');
      expect(HazardLabels.status(h, true), 'بلاغ غير صحيح');
      // English shows the server's own wording.
      expect(HazardLabels.status(h, false), 'Rejected (AI)');
    });
  });

  group('server names', () {
    test('English shows the server name verbatim', () {
      final h = _hazard(typeName: 'Water Leakage', statusName: 'Pending');
      expect(HazardLabels.type(h, false), 'Water Leakage');
      expect(HazardLabels.status(h, false), 'Pending');
    });

    test('Arabic translates known names case-insensitively', () {
      final h = _hazard(typeName: 'BROKEN MANHOLE', statusName: 'in progress');
      expect(HazardLabels.type(h, true), 'مناهل مكسورة');
      expect(HazardLabels.status(h, true), 'قيد العمل');
    });

    test('Arabic falls back to the id label for an unknown server name', () {
      final h = _hazard(typeId: 2, typeName: 'Something New', statusId: 3, statusName: 'Weird');
      expect(HazardLabels.type(h, true), 'تشقق');
      expect(HazardLabels.status(h, true), 'محلول');
    });

    test('empty server name uses the id', () {
      final h = _hazard(typeId: 4, typeName: '  ', statusId: 2, statusName: '');
      expect(HazardLabels.type(h, false), 'Broken Manhole');
      expect(HazardLabels.status(h, false), 'In Progress');
    });
  });

  test('every type and status id has non-empty labels in both languages', () {
    for (final id in [0, 1, 2, 3, 4, 99]) {
      for (final ar in [true, false]) {
        expect(HazardLabels.typeById(id, ar), isNotEmpty);
        expect(HazardLabels.statusById(id, ar), isNotEmpty);
      }
    }
  });
}
