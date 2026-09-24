import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'report_trigger_policy.dart';

/// One line per detection episode, to `debugPrint` and to
/// `<appSupport>/episodes.jsonl` (rotated at 2 MB), so the trigger gates can
/// be tuned from real drives instead of guessed. `adb pull` the file, or read
/// it with any JSONL tool.
///
/// Key derived numbers:
///  * `speed * tEndFromTrigMs / 1000 + 3` ≈ metres from the trigger point to
///    the pothole → calibrates the GPS look-ahead;
///  * `fps` = (hits + misses) / duration → verifies FPS-independence;
///  * `trigWpx` (box width at trigger) → whether a late-firing photo mode is
///    worth building (median < ~35 px means small photos).
class EpisodeLog {
  EpisodeLog._();

  static final EpisodeLog instance = EpisodeLog._();

  static const int _maxBytes = 2 * 1024 * 1024;
  static const String _fileName = 'episodes.jsonl';

  File? _file;
  bool _writing = false;
  final List<String> _queue = <String>[];

  /// Called on `episodeEnded` (rare, not on the hot path). Never throws.
  void write(
    ReportTriggerPolicy policy, {
    required String result,
    String? modelBackend,
  }) {
    final ep = policy.episode;
    final at = ep.endUs != 0 ? ep.endUs : ep.lastHitUs;
    final durMs = ep.durationMs(at);
    final frames = ep.hits + ep.misses;
    final fps = durMs > 0 ? frames * 1000.0 / durMs : 0.0;
    final tEndFromTrigMs =
        ep.triggerUs == 0 ? null : ((ep.lastHitUs - ep.triggerUs) / 1000).round();

    final record = <String, Object?>{
      'ep': ep.id,
      't0': DateTime.fromMicrosecondsSinceEpoch(ep.startUs).toIso8601String(),
      'durMs': durMs.round(),
      'hits': ep.hits,
      'misses': ep.misses,
      'hitMs': ep.hitMs.round(),
      'density': _r(ep.density),
      'elapsedMs': ep.elapsedMs.round(),
      'fps': _r(fps, 1),
      'peak': _r(ep.peak),
      'peakWpx': ep.peakBoxWpx.round(),
      'meanConf': _r(ep.meanConf),
      'trigMs': ep.triggerUs == 0 ? null : ((ep.triggerUs - ep.startUs) / 1000).round(),
      'trigWpx': ep.triggerUs == 0 ? null : ep.triggerBoxWpx.round(),
      'trigConf': ep.triggerUs == 0 ? null : _r(ep.triggerConf),
      'trigCy': ep.triggerUs == 0 ? null : _r(ep.triggerCy),
      'trigHits': ep.triggerUs == 0 ? null : ep.triggerHits,
      'tEndFromTrigMs': tEndFromTrigMs,
      'speed': _nan(ep.speedMps, 1),
      'gpsAcc': _nan(ep.gpsAccuracyM, 0),
      'heading': _nan(ep.headingDeg, 0),
      'fixSource': ep.fixSource.isEmpty ? null : ep.fixSource,
      'maxSim': ep.maxSimultaneous,
      'maxJump': _r(ep.maxJumpPerSec, 1),
      'result': result,
      'backend': modelBackend,
      'trace': ep.trace.dump(),
    };

    final line = jsonEncode(record);
    debugPrint(
      '🧭 episode ${ep.id} | ${durMs.round()} ms | hits ${ep.hits}/$frames '
      '| peak ${_r(ep.peak)} | trigWpx ${record['trigWpx'] ?? '-'} '
      '| tEndFromTrig ${tEndFromTrigMs ?? '-'} | $result',
    );
    _queue.add(line);
    // ignore: discarded_futures
    _flush();
  }

  static double _r(double v, [int digits = 2]) =>
      double.parse(v.toStringAsFixed(digits));

  static double? _nan(double v, int digits) =>
      v.isNaN ? null : double.parse(v.toStringAsFixed(digits));

  Future<void> _flush() async {
    if (_writing) return;
    _writing = true;
    try {
      final file = await _openFile();
      while (_queue.isNotEmpty) {
        final batch = _queue.join('\n');
        _queue.clear();
        await file.writeAsString('$batch\n', mode: FileMode.append, flush: true);
      }
      if (await file.length() > _maxBytes) {
        final rotated = File('${file.path}.1');
        if (await rotated.exists()) await rotated.delete();
        await file.rename(rotated.path);
        _file = null;
      }
    } catch (e) {
      debugPrint('⚠️ episode log write failed: $e');
      _queue.clear();
    } finally {
      _writing = false;
    }
  }

  Future<File> _openFile() async {
    final cached = _file;
    if (cached != null) return cached;
    final dir = await getApplicationSupportDirectory();
    final file = File('${dir.path}${Platform.pathSeparator}$_fileName');
    _file = file;
    return file;
  }
}
