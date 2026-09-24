/// Decides WHEN a stream of per-frame pothole detections becomes one report.
///
/// Pure Dart, no Flutter imports, time injected — unit-testable with synthetic
/// 8 FPS / 25 FPS sequences.
///
/// Model: an *episode* is one contiguous run of "hit" frames (a pothole in
/// view). One episode → at most one report. The rule is time-based, so it
/// behaves the same on a phone processing 8 or 25 frames per second:
///
///  * a frame is a **hit** when the best pothole box has conf ≥ [tHit] and is
///    at least [minBoxPx] wide in model-input pixels (noise floor; width is
///    used because dashboard perspective foreshortens height);
///  * each hit earns **hit-time** = time since the previous result, clamped to
///    [dtClampMs] (one GPU stall cannot buy a confirmation);
///  * the report **fires** when hits ≥ [minHits], hit-time ≥ [minHitMs],
///    density (hit-time / episode duration) ≥ [minDensity] and the episode's
///    peak confidence ≥ [tPeak];
///  * the episode **ends** (and re-arms) after [gapMs] without a hit. After a
///    report the episode stays `reported` until then, so a car stopped in
///    front of a pothole never fires twice.
library;

import 'dart:math' as math;
import 'dart:typed_data';

enum EpisodeState { idle, active, reported }

enum PolicyAction { none, episodeStarted, fire, episodeEnded }

/// Bit flags recorded on an episode when a `fire` was suppressed by the UI.
abstract final class SuppressReason {
  static const int cooldown = 1;
  static const int dedupe = 2;
  static const int busy = 4;
  static const int noSnapshot = 8;
  static const int noWorker = 16;

  static String describe(int mask) {
    if (mask == 0) return '';
    final parts = <String>[];
    if (mask & cooldown != 0) parts.add('cooldown');
    if (mask & dedupe != 0) parts.add('dedupe');
    if (mask & busy != 0) parts.add('busy');
    if (mask & noSnapshot != 0) parts.add('noSnapshot');
    if (mask & noWorker != 0) parts.add('noWorker');
    return parts.join(',');
  }
}

/// Fixed-size ring buffer of the last results (for the episode log only).
/// Parallel typed arrays: zero allocation after construction.
class Trace {
  Trace(this.capacity)
      : conf = Float32List(capacity),
        boxWpx = Float32List(capacity),
        cy = Float32List(capacity),
        dtMs = Uint16List(capacity);

  final int capacity;
  final Float32List conf;
  final Float32List boxWpx;
  final Float32List cy;
  final Uint16List dtMs;
  int _head = 0;
  int length = 0;

  void clear() {
    _head = 0;
    length = 0;
  }

  void push(double c, double wPx, double y, int dt) {
    conf[_head] = c;
    boxWpx[_head] = wPx;
    cy[_head] = y;
    dtMs[_head] = dt < 0 ? 0 : (dt > 65535 ? 65535 : dt);
    _head = (_head + 1) % capacity;
    if (length < capacity) length++;
  }

  /// Oldest first: `conf/widthPx` per result, `-` for a miss.
  String dump() {
    final sb = StringBuffer();
    final start = (_head - length + capacity) % capacity;
    for (int i = 0; i < length; i++) {
      final k = (start + i) % capacity;
      if (i > 0) sb.write(' ');
      if (conf[k] <= 0) {
        sb.write('-');
      } else {
        sb
          ..write(conf[k].toStringAsFixed(2))
          ..write('/')
          ..write(boxWpx[k].round());
      }
    }
    return sb.toString();
  }
}

/// All state of the current (or last finished) episode. Primitives only,
/// reset in place; the UI adds GPS/speed context at fire / end time.
class Episode {
  EpisodeState state = EpisodeState.idle;
  int id = 0;

  int startUs = 0;
  int lastHitUs = 0;
  int endUs = 0;
  int triggerUs = 0;

  int hits = 0;
  int misses = 0;
  int maxSimultaneous = 0;

  /// Time credited to hits (per-result dt, clamped).
  double hitMs = 0;

  /// Time credited to all results (same clamp), so density is unaffected by
  /// a worker stall. Wall-clock length is [durationMs].
  double elapsedMs = 0;
  double sumConf = 0;

  double peak = 0;
  double peakBoxWpx = 0;
  int peakFrameId = 0;

  double firstCx = 0, firstCy = 0;
  double lastCx = 0, lastCy = 0;
  double maxJumpPerSec = 0;

  double triggerConf = 0;
  double triggerBoxWpx = 0;
  double triggerCy = 0;
  int triggerHits = 0;
  double triggerHitMs = 0;

  int suppressMask = 0;

  // Context filled in by the UI (NaN / empty = unknown).
  double speedMps = double.nan;
  double gpsAccuracyM = double.nan;
  double headingDeg = double.nan;
  String fixSource = '';

  final Trace trace = Trace(64);

  /// Wall-clock length of the episode in ms (to the end, or to the last
  /// result while still running).
  double durationMs(int nowUs) =>
      ((endUs != 0 ? endUs : nowUs) - startUs) / 1000.0;

  /// Share of (clamped) episode time on which the detector said "yes".
  double get density =>
      elapsedMs <= 0 ? 1.0 : (hitMs / elapsedMs).clamp(0.0, 1.0);

  double get meanConf => hits == 0 ? 0 : sumConf / hits;

  bool get reported => triggerUs != 0;

  void reset() {
    state = EpisodeState.idle;
    startUs = 0;
    lastHitUs = 0;
    endUs = 0;
    triggerUs = 0;
    hits = 0;
    misses = 0;
    maxSimultaneous = 0;
    hitMs = 0;
    elapsedMs = 0;
    sumConf = 0;
    peak = 0;
    peakBoxWpx = 0;
    peakFrameId = 0;
    firstCx = 0;
    firstCy = 0;
    lastCx = 0;
    lastCy = 0;
    maxJumpPerSec = 0;
    triggerConf = 0;
    triggerBoxWpx = 0;
    triggerCy = 0;
    triggerHits = 0;
    triggerHitMs = 0;
    suppressMask = 0;
    speedMps = double.nan;
    gpsAccuracyM = double.nan;
    headingDeg = double.nan;
    fixSource = '';
    trace.clear();
  }
}

class ReportTriggerPolicy {
  ReportTriggerPolicy({
    required this.inputWidthPx,
    this.tHit = 0.30,
    this.tPeak = 0.45,
    this.minBoxPx = 16.0,
    this.minHitMs = 300.0,
    this.minHits = 3,
    this.minDensity = 0.5,
    this.gapMs = 400,
    this.dtClampMs = 250,
  });

  /// Model input width, to turn a normalised box width into pixels.
  final int inputWidthPx;

  /// A frame counts as a hit at this confidence (episode continuity).
  final double tHit;

  /// The episode must reach this confidence on at least one frame to fire.
  final double tPeak;

  /// Boxes narrower than this (model-input pixels) are ignored as noise.
  final double minBoxPx;

  final double minHitMs;
  final int minHits;
  final double minDensity;

  /// Episode ends after this long without a hit.
  final int gapMs;

  /// Max hit-time credited by one result (guards against worker stalls).
  final int dtClampMs;

  final Episode episode = Episode();
  int _lastResultUs = 0;
  int _nextId = 1;

  EpisodeState get state => episode.state;

  /// Feed one processed frame. `conf`/`widthNorm`/`cx`/`cy` describe the best
  /// pothole box (conf 0 when none); `hitCount` is the number of pothole
  /// boxes with conf ≥ [tHit] in the frame (for the log only).
  PolicyAction onFrame({
    required int nowUs,
    required int frameId,
    required double conf,
    required double widthNorm,
    required double cx,
    required double cy,
    required int hitCount,
  }) {
    int dtUs = _lastResultUs == 0 ? 0 : nowUs - _lastResultUs;
    if (dtUs < 0) dtUs = 0;
    final clampUs = dtClampMs * 1000;
    if (dtUs > clampUs) dtUs = clampUs;
    _lastResultUs = nowUs;

    final wPx = widthNorm * inputWidthPx;
    final isHit = conf >= tHit && wPx >= minBoxPx;
    final ep = episode;

    switch (ep.state) {
      case EpisodeState.idle:
        if (!isHit) return PolicyAction.none;
        ep.reset();
        ep.id = _nextId++;
        ep.state = EpisodeState.active;
        // Start the clock where this hit's credit begins, so density is
        // exactly 1.0 for an all-hit run.
        ep.startUs = nowUs - dtUs;
        ep.firstCx = cx;
        ep.firstCy = cy;
        _recordHit(nowUs, dtUs, frameId, conf, wPx, cx, cy, hitCount);
        return PolicyAction.episodeStarted;

      case EpisodeState.active:
        if (isHit) {
          _recordHit(nowUs, dtUs, frameId, conf, wPx, cx, cy, hitCount);
          if (_confirmed(nowUs)) {
            ep.triggerUs = nowUs;
            ep.triggerConf = conf;
            ep.triggerBoxWpx = wPx;
            ep.triggerCy = cy;
            ep.triggerHits = ep.hits;
            ep.triggerHitMs = ep.hitMs;
            ep.state = EpisodeState.reported;
            return PolicyAction.fire;
          }
          return PolicyAction.none;
        }
        _recordMiss(dtUs);
        if (_gapElapsed(nowUs)) return _end(nowUs);
        return PolicyAction.none;

      case EpisodeState.reported:
        if (isHit) {
          // Keep counting: time-to-end after the trigger calibrates the GPS
          // look-ahead from real drives.
          _recordHit(nowUs, dtUs, frameId, conf, wPx, cx, cy, hitCount);
          return PolicyAction.none;
        }
        _recordMiss(dtUs);
        if (_gapElapsed(nowUs)) return _end(nowUs);
        return PolicyAction.none;
    }
  }

  bool _gapElapsed(int nowUs) => nowUs - episode.lastHitUs >= gapMs * 1000;

  PolicyAction _end(int nowUs) {
    episode.endUs = nowUs;
    episode.state = EpisodeState.idle;
    return PolicyAction.episodeEnded;
  }

  bool _confirmed(int nowUs) {
    final ep = episode;
    return ep.hits >= minHits &&
        ep.hitMs >= minHitMs &&
        ep.density >= minDensity &&
        ep.peak >= tPeak;
  }

  void _recordHit(
    int nowUs,
    int dtUs,
    int frameId,
    double conf,
    double wPx,
    double cx,
    double cy,
    int hitCount,
  ) {
    final ep = episode;
    ep.hits++;
    ep.hitMs += dtUs / 1000.0;
    ep.elapsedMs += dtUs / 1000.0;
    ep.sumConf += conf;
    if (conf > ep.peak) {
      ep.peak = conf;
      ep.peakBoxWpx = wPx;
      ep.peakFrameId = frameId;
    }
    if (ep.lastHitUs != 0 && dtUs > 0) {
      final dx = cx - ep.lastCx;
      final dy = cy - ep.lastCy;
      final jump = math.sqrt(dx * dx + dy * dy) / (dtUs / 1e6);
      if (jump > ep.maxJumpPerSec) ep.maxJumpPerSec = jump;
    }
    ep.lastCx = cx;
    ep.lastCy = cy;
    ep.lastHitUs = nowUs;
    if (hitCount > ep.maxSimultaneous) ep.maxSimultaneous = hitCount;
    ep.trace.push(conf, wPx, cy, dtUs ~/ 1000);
  }

  void _recordMiss(int dtUs) {
    episode.misses++;
    episode.elapsedMs += dtUs / 1000.0;
    episode.trace.push(0, 0, 0, dtUs ~/ 1000);
  }

  /// Which fire gates the (finished or running) episode fails. Empty when it
  /// reported. Evaluate after `episodeEnded`.
  List<String> unconfirmedReasons() {
    final ep = episode;
    if (ep.reported) return const <String>[];
    final reasons = <String>[];
    if (ep.hits < minHits) reasons.add('tooFewHits(${ep.hits})');
    if (ep.hitMs < minHitMs) reasons.add('tooShort(${ep.hitMs.round()}ms)');
    if (ep.density < minDensity) {
      reasons.add('lowDensity(${ep.density.toStringAsFixed(2)})');
    }
    if (ep.peak < tPeak) reasons.add('lowPeak(${ep.peak.toStringAsFixed(2)})');
    return reasons;
  }
}
