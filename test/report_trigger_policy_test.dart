// Pure Dart: runs with `dart test test/report_trigger_policy_test.dart`
// (no Flutter engine, no shader compilation) as well as with `flutter test`.
import 'package:tareeqi/services/report_trigger_policy.dart';
import 'package:test/test.dart';

/// Drives the policy with a synthetic frame stream at a fixed FPS.
class _Sim {
  _Sim({int fps = 10, int inputWidthPx = 416})
      : dtUs = (1e6 / fps).round(),
        policy = ReportTriggerPolicy(inputWidthPx: inputWidthPx) {
    // In the app results stream continuously before the first hit, so the
    // policy already has a previous-result timestamp. Mirror that here.
    policy.onFrame(
      nowUs: nowUs,
      frameId: 0,
      conf: 0,
      widthNorm: 0,
      cx: 0,
      cy: 0,
      hitCount: 0,
    );
  }

  final int dtUs;
  final ReportTriggerPolicy policy;
  int nowUs = 1000000;
  int frameId = 0;
  final List<PolicyAction> actions = <PolicyAction>[];

  /// `conf` 0 = miss. Box width defaults to 10 % of the model input.
  PolicyAction frame(double conf, {double widthNorm = 0.10, int? dtOverrideUs}) {
    nowUs += dtOverrideUs ?? dtUs;
    frameId++;
    final a = policy.onFrame(
      nowUs: nowUs,
      frameId: frameId,
      conf: conf,
      widthNorm: conf > 0 ? widthNorm : 0,
      cx: 0.5,
      cy: 0.6,
      hitCount: conf >= policy.tHit ? 1 : 0,
    );
    actions.add(a);
    return a;
  }

  int run(List<double> confs) {
    int fires = 0;
    for (final c in confs) {
      if (frame(c) == PolicyAction.fire) fires++;
    }
    return fires;
  }

  int get fires => actions.where((a) => a == PolicyAction.fire).length;
}

void main() {
  group('ReportTriggerPolicy', () {
    test('25 FPS: steady hits fire ~300 ms of hit-time after the first hit',
        () {
      final sim = _Sim(fps: 25);
      int? fireFrame;
      for (int i = 0; i < 20; i++) {
        if (sim.frame(0.6) == PolicyAction.fire) {
          fireFrame = i + 1;
          break;
        }
      }
      expect(fireFrame, isNotNull);
      // 40 ms per hit → 8th hit reaches 320 ms.
      expect(fireFrame, 8);
      expect(sim.policy.episode.hitMs, greaterThanOrEqualTo(300));
    });

    test('8 FPS: fires on the 3rd hit', () {
      final sim = _Sim(fps: 8);
      expect(sim.frame(0.6), PolicyAction.episodeStarted);
      expect(sim.frame(0.6), PolicyAction.none);
      expect(sim.frame(0.6), PolicyAction.fire);
    });

    test('flicker around the hit threshold still confirms if peak reached',
        () {
      final sim = _Sim(fps: 10);
      // Old rule (3 strictly consecutive >= 0.35) would never fire here.
      final fires = sim.run([0.34, 0.36, 0.33, 0.40, 0.47, 0.44]);
      expect(fires, 1);
    });

    test('never reaches peak → unconfirmed:lowPeak, one episode, no fire',
        () {
      final sim = _Sim(fps: 10);
      // 5 hits, then exactly 4 misses = 400 ms gap at 10 FPS.
      final fires = sim.run([0.34, 0.36, 0.33, 0.40, 0.38, 0.0, 0.0, 0.0, 0.0]);
      expect(fires, 0);
      expect(sim.actions.last, PolicyAction.episodeEnded);
      expect(sim.policy.unconfirmedReasons().join(','), contains('lowPeak'));
    });

    test('1-in-4 flicker fails density even over a long time', () {
      final sim = _Sim(fps: 20); // 50 ms frames; gap 400 ms = 8 frames
      final seq = <double>[];
      for (int i = 0; i < 40; i++) {
        seq.add(i % 4 == 0 ? 0.6 : 0.0); // one hit then three misses
      }
      seq.addAll(List.filled(10, 0.0));
      final fires = sim.run(seq);
      expect(fires, 0);
      expect(sim.policy.unconfirmedReasons().join(','), contains('lowDensity'));
    });

    test('10 s of continuous hits fires exactly once (stopped in traffic)',
        () {
      final sim = _Sim(fps: 10);
      final fires = sim.run(List.filled(100, 0.7));
      expect(fires, 1);
      expect(sim.policy.state, EpisodeState.reported);
    });

    test('400 ms gap ends the episode and re-arms', () {
      final sim = _Sim(fps: 10); // 100 ms frames
      sim.run(List.filled(5, 0.7)); // fires
      expect(sim.fires, 1);
      // 4 misses = 400 ms → episodeEnded on the 4th.
      expect(sim.frame(0), PolicyAction.none);
      expect(sim.frame(0), PolicyAction.none);
      expect(sim.frame(0), PolicyAction.none);
      expect(sim.frame(0), PolicyAction.episodeEnded);
      expect(sim.policy.state, EpisodeState.idle);
      // A second pothole → a second report.
      sim.run(List.filled(5, 0.7));
      expect(sim.fires, 2);
    });

    test('a single miss inside a run does not split the episode', () {
      final sim = _Sim(fps: 10);
      final fires = sim.run([0.6, 0.0, 0.6, 0.6, 0.6, 0.6]);
      expect(fires, 1);
      expect(sim.policy.episode.id, 1);
    });

    test('worker stall: hit-time is clamped, two hits cannot confirm', () {
      final sim = _Sim(fps: 10);
      expect(sim.frame(0.7), PolicyAction.episodeStarted);
      // 800 ms stall → credited only 250 ms → 350 ms total but only 2 hits.
      expect(sim.frame(0.7, dtOverrideUs: 800000), PolicyAction.none);
      expect(sim.policy.episode.hitMs, lessThanOrEqualTo(350));
      expect(sim.frame(0.7), PolicyAction.fire); // 3rd hit
    });

    test('boxes narrower than minBoxPx are ignored', () {
      final sim = _Sim(fps: 10, inputWidthPx: 416);
      final fires = sim.run(List.filled(10, 0.9));
      expect(fires, 1); // sanity: default width (41 px) fires
      // 10 px wide at 416 → below the 16 px floor → never a hit.
      final narrow = _Sim(fps: 10, inputWidthPx: 416);
      for (int i = 0; i < 10; i++) {
        expect(narrow.frame(0.9, widthNorm: 10 / 416), PolicyAction.none);
      }
      expect(narrow.policy.state, EpisodeState.idle);
    });
  });
}
