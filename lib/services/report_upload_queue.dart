import 'dart:collection';
import 'dart:io';

import 'package:camera/camera.dart' show XFile;
import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:path_provider/path_provider.dart';

import 'api_service.dart';
import 'offline_queue.dart';

/// A pothole report waiting to be uploaded.
class PendingReport {
  const PendingReport({
    required this.jpeg,
    required this.capturedAt,
    this.latitude,
    this.longitude,
    this.typeId = 1, // pothole
  });

  final Uint8List jpeg;
  final DateTime capturedAt;
  final double? latitude;
  final double? longitude;
  final int typeId;
}

enum ReportOutcomeKind { sent, failed, savedOffline, noLocation }

class ReportOutcome {
  ReportOutcome(this.kind, {this.message}) : at = DateTime.now();

  final ReportOutcomeKind kind;
  final String? message;
  final DateTime at;
}

/// Fire-and-forget uploader.
///
/// The live camera screen calls [enqueue] and returns immediately; uploads
/// run one at a time in the background, so detection never pauses for GPS,
/// photo capture or the network. The JPEG is written to disk first because
/// [ApiService.submitReport] stores `photo.path` in [OfflineQueue] on failure.
class ReportUploadQueue {
  ReportUploadQueue._();

  static final ReportUploadQueue instance = ReportUploadQueue._();

  static const Duration _uploadTimeout = Duration(seconds: 30);
  static const Duration _gpsWait = Duration(seconds: 20);

  /// Reports written to disk but not yet uploaded (drives the UI pill).
  final ValueNotifier<int> pending = ValueNotifier<int>(0);

  /// Last upload outcome, for a single SnackBar per result.
  final ValueNotifier<ReportOutcome?> lastOutcome =
      ValueNotifier<ReportOutcome?>(null);

  final Queue<_Job> _jobs = Queue<_Job>();
  bool _draining = false;
  Directory? _reportsDir;

  Future<void> enqueue(PendingReport report) async {
    pending.value = pending.value + 1;
    final String path;
    try {
      final dir = await _directory();
      final file = File(
        '${dir.path}${Platform.pathSeparator}'
        'pothole_${report.capturedAt.millisecondsSinceEpoch}.jpg',
      );
      await file.writeAsBytes(report.jpeg, flush: true);
      path = file.path;
    } catch (e) {
      pending.value = pending.value - 1;
      debugPrint('❌ Could not save report photo: $e');
      lastOutcome.value = ReportOutcome(
        ReportOutcomeKind.failed,
        message: 'Could not save photo: $e',
      );
      return;
    }
    _jobs.add(_Job(path: path, report: report));
    // Not awaited: the caller must never wait on the network.
    // ignore: discarded_futures
    _drain();
  }

  Future<Directory> _directory() async {
    final cached = _reportsDir;
    if (cached != null) return cached;
    final base = await getApplicationSupportDirectory();
    final dir = Directory('${base.path}${Platform.pathSeparator}reports');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    _reportsDir = dir;
    return dir;
  }

  Future<void> _drain() async {
    if (_draining) return;
    _draining = true;
    try {
      while (_jobs.isNotEmpty) {
        final job = _jobs.removeFirst();
        try {
          await _process(job);
        } catch (e) {
          debugPrint('❌ Report upload crashed: $e');
          lastOutcome.value =
              ReportOutcome(ReportOutcomeKind.failed, message: '$e');
        } finally {
          pending.value = pending.value - 1;
        }
      }
    } finally {
      _draining = false;
    }
  }

  Future<void> _process(_Job job) async {
    double? lat = job.report.latitude;
    double? lon = job.report.longitude;

    // The camera screen normally attaches a live GPS fix. If none was
    // available at capture time, wait for one here — off the detection path.
    if (lat == null || lon == null) {
      try {
        final position = await Geolocator.getCurrentPosition(
          locationSettings: const LocationSettings(
            accuracy: LocationAccuracy.high,
          ),
        ).timeout(_gpsWait);
        lat = position.latitude;
        lon = position.longitude;
      } catch (e) {
        debugPrint('⚠️ No GPS fix for report: $e');
      }
    }

    final stamp = job.report.capturedAt.toIso8601String();
    if (lat == null || lon == null) {
      await OfflineQueue.save(<String, dynamic>{
        'lat': 0.0,
        'lon': 0.0,
        'typeId': job.report.typeId,
        'imagePath': job.path,
        'time': stamp,
        'needsLocation': true,
      });
      lastOutcome.value = ReportOutcome(
        ReportOutcomeKind.noLocation,
        message: 'Saved without location',
      );
      return;
    }

    bool success;
    try {
      success = await ApiService.submitReport(
        photo: XFile(job.path),
        latitude: lat,
        longitude: lon,
        typeId: job.report.typeId,
      ).timeout(_uploadTimeout);
    } catch (e) {
      // A timeout thrown here bypasses submitReport's own offline save.
      debugPrint('⚠️ Report upload timed out / failed: $e');
      await OfflineQueue.save(<String, dynamic>{
        'lat': lat,
        'lon': lon,
        'typeId': job.report.typeId,
        'imagePath': job.path,
        'time': stamp,
      });
      lastOutcome.value = ReportOutcome(
        ReportOutcomeKind.savedOffline,
        message: 'Upload timed out — saved offline',
      );
      return;
    }

    if (success) {
      try {
        await File(job.path).delete();
      } catch (_) {
        // Not important; the file is small.
      }
      lastOutcome.value = ReportOutcome(ReportOutcomeKind.sent);
    } else {
      // submitReport already queued it offline where appropriate.
      lastOutcome.value = ReportOutcome(
        ReportOutcomeKind.failed,
        message: ApiService.lastReportError,
      );
    }
  }
}

class _Job {
  const _Job({required this.path, required this.report});
  final String path;
  final PendingReport report;
}
