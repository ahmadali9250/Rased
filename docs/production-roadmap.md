# Production roadmap — live pothole detection

Companion to [live-detection.md](live-detection.md), which describes the
system as it exists today. This document lists what stands between the
current working tree and a version that a municipal fleet can rely on, in the
order it should be done. Dates are relative to the first on-device build.

Definition of "production ready" used here:

- ≥ 80 % of known potholes on a test route reported, ≤ 1 duplicate per
  pothole, false reports well below one per kilometre of clean road.
- ≥ 10 processed FPS with zero UI jank on the weakest fleet phone, sustained
  for a 60-minute drive on a charger without thermal collapse.
- No detection blackout during uploads, GPS waits or network loss; nothing
  lost when offline.
- Release-signed build with a real application id, crash reporting, and a
  way to change thresholds and models without a store release.
- A labelled regression set and a repeatable measurement so every model or
  threshold change is accepted or rejected on numbers.

---

## Phase 0 — First build and on-device validation (week 1)

Goal: prove the pipeline on real hardware and fix what the phone reveals.

| # | Task | Exit criterion |
|---|---|---|
| 0.1 | Dev machine: Android SDK installed, Flutter SDK on PATH, Smart App Control exclusion for the Flutter folder (it blocks the shader compiler). | `flutter doctor` green for Android; `flutter build apk --release --split-per-abi` succeeds. |
| 0.2 | Commit the current working tree as the baseline. | Clean `git status`. |
| 0.3 | Install on the Galaxy A25 (primary demo phone). Read the 2-second diagnostics line in logcat (`flutter logs`). | Backend name and `proc` FPS recorded with the 640 model. Expect GPU or `CPU/XNNPACK-fp16`. |
| 0.4 | Trigger one report; inspect the JPEG. | Photo upright. If rotated, fix `_updateRotation` (rotation sign) and re-test. |
| 0.5 | Export E1 (416 e2e) and E2 (416 raw) with `YoloModel/export_model.py`; check both with `assets/check_model.py`; add to `pubspec.yaml` and `benchModelAssets`; bench each fleet phone by switching `TFLiteService.defaultModelAsset` and reading the logcat diagnostics line. | Per-device table: model × backend → `proc` FPS, `inv` ms, `jank`. Pick the shipping model per device class. |
| 0.6 | Bench-top test with a pothole video on a laptop screen: one report per pass, upload pill visible while boxes keep moving, airplane mode → offline queue. | All three behaviours observed. |
| 0.7 | Fix whatever 0.3–0.6 surfaces. | Analyzer clean, tests green, re-verified on device. |

---

## Phase 1 — Field validation and tuning (weeks 2–4)

Goal: real drives, real numbers, tuned gates.

| # | Task | Exit criterion |
|---|---|---|
| 1.1 | Define a 5 km test route with ≥ 5 known potholes (photographed and pinned). Drive it at 40–60 km/h with old and new builds. | Detected/total, reports created, duplicates, GPS error per report, `jank` bursts, worker errors — all recorded. |
| 1.2 | Pull `episodes.jsonl` after each drive. Classify every episode as true pothole / false alarm using the trigger photo. | A spreadsheet of episodes with ground truth. |
| 1.3 | Tune `tPeak` (0.40–0.50), `tHit`, `minHitMs` from the episode data; calibrate `lookAheadMeters` from `speed × tEndFromTrig`. | Gates chosen on data, written into the policy defaults with the drive date in a comment. |
| 1.4 | Decide on the late-firing photo mode from median `trigWpx` (build it only if photos are small, < ~35 px). | Decision recorded here. |
| 1.5 | Stopped-in-traffic test in front of a pothole for 30 s; return-leg test over the same potholes. | Exactly one report each way. |
| 1.6 | 60-minute continuous drive on a charger in daytime heat. Watch `proc` and `inv` over time. | No more than a 30 % FPS drop from thermal throttling; if worse, lower `maxProcessFps` or switch that device class to the 320/int8 model. |

Acceptance for leaving Phase 1: the recall/duplicate/false-report targets
above, on the test route, with the chosen model per device class.

---

## Phase 2 — Data and model (months 1–2, parallel with Phase 1)

Goal: a model measured on your roads, not on internet datasets. The detailed
ML plan (measurement, data collection, training recipe, improvement loop and
targets) is in [ai-accuracy-roadmap.md](ai-accuracy-roadmap.md); the rows
below are the summary.

| # | Task | Exit criterion |
|---|---|---|
| 2.1 | Retrieve the current model's metrics from `rased_training/rased_yolo26/v1_yolo26n/results.csv` (or `yolo val`). Record them in this repo. | Baseline mAP50 / precision / recall documented. |
| 2.2 | Fix `YoloModel/merge_datasets.py`: shuffle with a fixed seed before splitting; keep Roboflow's original splits or deduplicate augmented copies so nothing leaks between train and val. | Re-generated dataset; val contains every source. |
| 2.3 | Collect local dashboard footage on the fleet phones (the app already saves the trigger JPEG; add a debug option to save uncertain episodes if needed). Label 500–1500 frames. Add ~10 % background frames with manholes, patches, shadows, wet spots. | Labelled local set merged into training data. |
| 2.4 | Build a **fixed regression set** of ~200 labelled local frames that is never trained on. | Script that prints recall, precision and false positives per frame at the app's threshold. |
| 2.5 | Retrain at 416 with the backbone unfrozen; compare against 2.1 on the regression set. Then try yolo26s at 416 if the GPU phones have headroom. | Model chosen on regression-set numbers, not training mAP. |
| 2.6 | Export the winner (E2 raw if GPU-verified, plus int8 for CPU-only phones). Ship with a model metadata file (`assets/model.json`: name, imgsz, layout, thresholds, training date, regression numbers). | App reads thresholds from metadata rather than constants. |
| 2.7 | Add `flutter test` + `dart test` + analyzer to CI so no model or code change lands without them. | CI green on every PR. |

---

## Phase 3 — App hardening for production (month 2)

Goal: the app survives a working day in a car and a fleet of phones.

### Must-have

| # | Task | Why |
|---|---|---|
| 3.1 | Keep the screen on while detecting (wakelock, e.g. `wakelock_plus`), release on exit/background. | A screen timeout pauses the app and stops detection silently. |
| 3.2 | Real `applicationId`, release signing config with a stored keystore, version bump policy. | Debug-signed `com.example.tareeqi` cannot ship. |
| 3.3 | Drain `OfflineQueue`: on app start and on connectivity change, upload saved reports with retry and backoff; delete JPEGs after success; cap queue size. | Reports saved offline are currently never sent. |
| 3.4 | Crash and error reporting (Sentry or Crashlytics), including worker errors and `AI ERROR` lines. | Field failures are invisible today without a USB cable. |
| 3.5 | Telemetry: upload the 2-second diagnostics summaries and `episodes.jsonl` (opt-in, batched on Wi-Fi) to a simple endpoint. | Threshold tuning and device-class decisions need fleet data, not one phone. |
| 3.6 | Remote configuration of trigger gates, FPS ceiling, model asset name and a kill switch, with safe defaults baked in. | Change behaviour without a store release. |
| 3.7 | Environment configuration for `ApiService.baseUrl` (dev / staging / prod) via build flavours. | A hard-coded URL cannot be promoted safely. |
| 3.8 | Permission flows: camera and location rationale screens, "precise location" prompt, graceful degraded mode when denied. | Android 12+ users can grant coarse location only. |
| 3.9 | Storage hygiene: cap `reports/` and logs, delete uploaded JPEGs, rotate logs. | A day of driving must not fill the phone. |
| 3.10 | Thermal management: if `inv` or round-trip grows > 50 % over the first minute, lower the FPS ceiling automatically; restore when it recovers. | Sustained drives in summer. |
| 3.11 | Battery: confirm behaviour with battery saver on; show a warning if optimisation is enabled for the app. | Samsung/Xiaomi kill background work aggressively. |
| 3.12 | R8/ProGuard keep rules for tflite_flutter and camerax in release builds; verify a release APK runs detection. | Minification breaks FFI/JNI symbol lookup if not configured. |
| 3.13 | Bump `minSdk` to 26+ if the fleet allows, `targetSdk` to current Play requirements. | Store policy and camerax behaviour. |
| 3.14 | Privacy: decide whether faces / licence plates in report photos need blurring before upload; document data retention. | Photos of public roads still contain people and cars. |

### Should-have

| # | Task |
|---|---|
| 3.15 | **Done 2026-09-25.** The diagnostics panel and long-press harness were removed from the camera screen; drivers see only the HUD (scanning / clear road / pothole detected / AI unavailable). The diagnostics line lives in logcat only. |
| 3.16 | Voice/sound cue on report in addition to vibration. |
| 3.17 | Night and low-light handling: check exposure behaviour; consider `ResolutionPreset.medium` vs high at night; measure recall at night on the regression set. |
| 3.18 | Session summary at the end of a drive (distance, reports, uploads pending). |
| 3.19 | Localisation review (Arabic/English) of all new strings. |

---

## Phase 4 — Backend and operations (month 3)

| # | Task |
|---|---|
| 4.1 | Server-side clustering of reports across trips and drivers (e.g. 20 m radius, DBSCAN as sketched in the original notebook) so one pothole is one work item. |
| 4.2 | Review dashboard: photo, map pin, confidence, cluster size, status workflow (already partly present in the admin screens). |
| 4.3 | Severity estimate from box size and position in frame (the notebook's heuristic) as a sortable field. |
| 4.4 | Model distribution: download `.tflite` + metadata from the backend with version checks instead of bundling, so model updates do not need an app release. Keep the bundled model as fallback. |
| 4.5 | Monitoring: reports per day per device, upload failure rate, model version in use, average `proc` FPS per device class. |

---

## Phase 5 — Later improvements (after production)

| # | Task | Trigger to start |
|---|---|---|
| 5.1 | Late-firing photo mode (fire when the box is ≥ 50 px wide or the pothole has passed; GPS taken at the pothole). | Median `trigWpx` < ~35 px in field logs. |
| 5.2 | Per-object tracking for several potholes in one frame. | `maxSim ≥ 2` in a meaningful share of episodes. |
| 5.3 | Native (Kotlin) preprocessing or CameraX → GPU zero-copy path. | Diagnostics show `pre` dominating on target phones after model changes. |
| 5.4 | Additional classes (cracks, broken manholes). | ≥ 500 local labelled examples per class. |
| 5.5 | iOS support (BGRA path exists in the sampler; Metal delegate untested). | Fleet requirement. |

---

## Risks and mitigations

| Risk | Mitigation |
|---|---|
| GPU delegate rejected or wrong on a device class | Fallback chain to CPU already in place; ship int8/320 for CPU-only classes; bench per device. |
| Rotation sign wrong on some OEM | First-photo check in Phase 0; make rotation overridable via remote config. |
| Thermal throttling on summer dashboards | FPS ceiling, adaptive ceiling (3.10), 320 model for hot devices, mount out of sun. |
| False reports flood the backend | Peak/density gates, hard-negative training data (2.3), server-side clustering (4.1), remote threshold tuning (3.6). |
| Duplicate reports on return legs | Spatial dedupe with 200 fixes plus server clustering. |
| GPS position 10–20 m off | Look-ahead calibrated from field logs (1.3); accuracy logged per report; clustering tolerates it. |
| Offline for long periods | Offline queue drain with backoff (3.3), storage caps (3.9). |
| Model regressions when retraining | Fixed regression set (2.4) and CI (2.7). |

---

## Immediate next actions

1. Phase 0.1–0.4 on the Galaxy A25.
2. Export E1/E2 and run the bench on all three fleet phones (0.5).
3. First test-route drive; pull `episodes.jsonl` (1.1–1.2).
4. Add the wakelock (3.1) before any demo.
