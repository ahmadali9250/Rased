# Live pothole detection — how it works today

Status: implemented in the working tree on 2026-09-24, analyzer-clean, 23 unit
tests passing. **Not yet run on a phone.** See the "Unverified on device"
section before trusting any behaviour described here as confirmed.

This document describes the live (dashcam) detection pipeline: the phone sits
on the dashboard, the app watches the road, and every pothole it confirms
becomes one report (photo + GPS) sent to the backend without the driver
touching the phone. For the plan to take this to production, see
[production-roadmap.md](production-roadmap.md).

---

## 1. Goals and constraints

| Goal | Target |
|---|---|
| Processed frames per second on a mid-range Android phone | ≥ 10 (capped at 15) |
| UI smoothness while detecting | 60 FPS preview, no dropped UI frames |
| Detection during a report upload | Never pauses |
| Reports per real pothole | Exactly one |
| Driving speed the trigger is tuned for | City, 30–70 km/h |
| Target fleet | Mixed Android, Samsung A-series / Redmi class and up. iOS is not a target. |

---

## 2. Architecture

```
Camera (camerax, 720x480 YUV420, ~30 FPS)
   │  CameraImage on the UI isolate
   ▼
LiveCameraScreen._onCameraFrame          lib/screens/live_camera_screen.dart
   • keep-newest back-pressure: at most ONE frame in flight,
     newer frames replace the pending one
   • 15 FPS ceiling (thermal)
   • rotation for the current device orientation
   ▼  FrameMsg (plane bytes, strides)            ── isolate boundary ──
Detection worker isolate                  lib/services/detection_worker.dart
   • owns the TFLite Interpreter + delegate (GPU → CPU/XNNPACK-fp16 → CPU)
   • FrameSampler: letterbox + rotate + YUV→RGB + normalise
                                           lib/services/frame_sampler.dart
   • invoke(), decode output (end-to-end / raw rows / raw cols)
   • keeps the last frame for the report photo (JPEG encode on request)
   ▼  ResultMsg (flat boxes, timings, letterbox geometry)
TFLiteService (main-isolate facade, singleton)   lib/services/tflite_service.dart
   ▼  DetectionResult
LiveCameraScreen._onDetectionResult
   • draws boxes (BoundingBoxPainter undoes letterbox + BoxFit.cover)
   • ReportTriggerPolicy: time-based episodes → fire once per pothole
                                           lib/services/report_trigger_policy.dart
   • on fire: vibrate, request JPEG from worker, project GPS fix,
     enqueue report — all without stopping the stream
   ▼
ReportUploadQueue (background, sequential)       lib/services/report_upload_queue.dart
   • writes JPEG to <appSupport>/reports/, uploads via ApiService.submitReport
   • falls back to OfflineQueue (SharedPreferences) on failure
EpisodeLog                                        lib/services/episode_log.dart
   • one JSON line per detection episode → <appSupport>/episodes.jsonl
```

Why an isolate: every per-frame step (colour conversion, inference, JPEG
encode) used to run on the UI thread and froze the preview. The worker owns
the interpreter outright; the UI isolate never touches TFLite.

Historical note: an earlier isolate attempt (commit `9d83b08`) was reverted
because of `Bad state: failed precondition`. The cause was invoking the
interpreter with `run([Float32List], out)`, which makes tflite_flutter resize
the input tensor, not the isolate itself. The worker writes the input through
`Tensor.data` and never calls `run()`.

---

## 3. Components

### 3.1 `FrameSampler` (pure Dart, unit-tested)

Converts one camera frame into the model input buffer in a single pass:

- Letterbox to the model input size with Ultralytics grey (114) padding.
  Padding is written once when geometry changes; per-frame work touches only
  the content rectangle.
- Rotation 0/90/180/270° clockwise (sensor frame → upright). For every
  rotation one of (source x, source y) depends only on the target column and
  the other only on the target row, so each sample costs two integer adds
  (`rowA + colA[tx]`), no multiplies.
- 2×2 luma box filter when downscaling ≥ 1.4× (720→416 is 1.73×). Closer to
  the linear/area resize used in training and steadier confidences than
  nearest-neighbour.
- YUV420 planar or semi-planar (pixel stride 2), BGRA (iOS) and packed RGB
  (still images). BT.601 full-range integer maths.
- Output as float32 0–1 (via a 256-entry lookup table), or int8 / uint8
  quantised with the tensor's scale and zero point. NCHW or NHWC.
- `toRgb()` decodes the buffer back for tests and debugging.

Tests: `test/frame_sampler_test.dart` (all rotations, box filter, chroma,
semi-planar, BGRA, NCHW, int8).

### 3.2 Detection worker

- Receives model bytes from the main isolate (moved, not copied) and opens
  them with `Interpreter.fromBuffer`; `rootBundle` is unavailable in a worker.
- Backend selection, each candidate must survive a real `invoke()`:
  1. **GPU** delegate (`isPrecisionLossAllowed`, MIN_LATENCY, up to 4
     partitions). After warm-up the worker idles 300 ms and invokes again:
     Dart isolates are not pinned to an OS thread, and the OpenGL GPU backend
     refuses to run on a different thread than it was prepared on (OpenCL only
     warns). If that second invoke fails the worker falls to CPU.
  2. **CPU/XNNPACK with FP16 arithmetic** (ARMv8.2+; ignored on older cores).
  3. **CPU/XNNPACK** without FP16.
  4. **Plain CPU.**
  NNAPI is off (deprecated from Android 15, per-vendor failures); a flag keeps
  it for int8 experiments.
- If an accelerated backend fails at invoke time later, the worker rebuilds a
  CPU interpreter in place and retries the same frame once.
- Output layouts supported, detected from the tensor shape:
  `[1, N, 6]` end-to-end (xyxy, conf, class); `[1, N, 4+nc]` raw rows (xyxy
  px + class scores, no NMS needed for YOLO26's one-to-one head; a light NMS
  runs only if more than one box survives); `[1, 4+nc, N]` legacy raw columns
  (cx,cy,w,h + scores, NMS). Pixel vs normalised coordinates are detected per
  box and divided by the real input size (the old code hard-coded 640).
- Per-stage `Stopwatch` timings travel with every result.
- Snapshot: full-frame YUV → RGB → rotate → JPEG (quality 80) inside the
  worker, ~50–80 ms once per report. The photo is the last processed frame
  (the trigger frame or the one after it, i.e. the closest view so far).
- Still images (manual report screen) go through the same sampler after a
  linear downscale.

### 3.3 `TFLiteService` (main isolate)

Singleton facade. Spawns the worker once (pre-warmed from `main.dart`),
forwards frames (`sendFrame` refuses while one is in flight), delivers
results through `onResult`, answers snapshot and still-image requests by id,
and exposes diagnostics events. Screens never dispose it; the worker stays
warm across screens. `restart()` switches model asset / backend preference
for the bench harness.

### 3.4 `ReportTriggerPolicy` (pure Dart, unit-tested)

Decides when a run of detections becomes a report. Time-based so it behaves
the same at 8 or 25 processed FPS.

| Gate | Default | Meaning |
|---|---|---|
| `tHit` | 0.30 | A frame is a *hit* when its best pothole box has at least this confidence… |
| `minBoxPx` | 16 px | …and is at least this wide in model-input pixels (noise floor; width because dashboard perspective foreshortens height). |
| hit-time | dt clamped to 250 ms | Each hit earns the time since the previous result; a worker stall cannot buy a confirmation. |
| `minHitMs` | 300 ms | Fire when the episode has this much hit-time… |
| `minHits` | 3 | …and at least this many hits… |
| `minDensity` | 0.50 | …and hits cover at least half the episode time (replaces "strictly consecutive frames")… |
| `tPeak` | 0.45 | …and one frame reached this confidence. |
| `gapMs` | 400 ms | Episode ends (and re-arms) after this long without a hit. One report per episode; a car stopped in front of a pothole never fires twice. |

Screen-side guards at fire time (recorded on the episode, never change
policy state): snapshot busy, worker not ready, 1 s minimum interval between
reports, spatial dedupe within 20 m of any of the last 200 report fixes.

GPS: continuous 1 Hz stream. The fix is projected forward by
`speed × age` (moving) plus a 12 m look-ahead along the heading, using the
last moving heading when stopped, because the camera sees the pothole ahead
of the antenna.

Tests: `test/report_trigger_policy_test.dart`.

### 3.5 `ReportUploadQueue`

Fire-and-forget. Writes the JPEG to `<appSupport>/reports/<epoch>.jpg`
(a real path, because `ApiService.submitReport` stores the path in
`OfflineQueue` on failure), uploads one at a time with a 30 s timeout, deletes
the file on success, saves to `OfflineQueue` on failure or timeout. If no GPS
fix was available at capture it waits up to 20 s for one here, off the
detection path. Exposes `pending` and `lastOutcome` notifiers for the UI pill
and SnackBars.

### 3.6 `EpisodeLog`

One JSON line per episode to `debugPrint` and `<appSupport>/episodes.jsonl`
(rotated at 2 MB). Fields include duration, hits/misses, hit-time, density,
FPS, peak and mean confidence, box width and confidence at trigger, time from
trigger to end of episode, speed, GPS accuracy, heading, fix source, max
simultaneous boxes, max box-centre jump, result
(`reported | suppressed:<reason> | unconfirmed:<reasons>`) and a compact
trace of the last 64 results.

Use it to tune the gates from real drives:

- `speed × tEndFromTrigMs / 1000 + 3` ≈ metres from trigger point to pothole
  → calibrates the GPS look-ahead.
- `fps` verifies FPS-independence across phones.
- `trigWpx` (box width at trigger) says whether photos are large enough; a
  median under ~35 px argues for a late-firing photo mode.

---

## 4. Model

| Item | Current |
|---|---|
| Asset | `assets/pothole_yolo26n_640_fp32.tflite` (9.8 MB) |
| Architecture | YOLO26n, 1 class (`pothole`), trained by `YoloModel/train_yolo26.py` at 640 with 10 backbone layers frozen |
| Input | `[1, 3, 640, 640]` float32 NCHW (ai-edge-torch export) |
| Output | `[1, 300, 6]` end-to-end (top-k tail baked in) |
| Precision | float32 (older comments claiming float16 were wrong) |

Naming convention: `assets/pothole_<arch>_<imgsz>_<precision>[_raw].tflite`.
Keep `pubspec.yaml` assets and `TFLiteService.benchModelAssets` in sync.

Export matrix (`YoloModel/export_model.py`, check each file with
`assets/check_model.py`, which prints shape, GPU-unfriendly ops and a rough
invoke time):

| ID | imgsz | Output | Precision | Purpose |
|---|---|---|---|---|
| E1 | 416 | end-to-end `[1,300,6]` | fp32 | Ship first; no parser change. Top-k tail stays on CPU with GPU delegate. |
| E2 | 416 | raw rows `[1,3549,5]` (postprocess stripped) | fp32 | Whole graph GPU-friendly. Preferred once verified. |
| E3 | 320 | raw rows | fp32 | Weak phones. |
| E4 | 416 | raw rows | int8 (PTQ) | CPU-only phones; 1.5–2.5× faster on XNNPACK. |
| E5 | 640 | end-to-end | fp32 | Current model; accuracy baseline only. Too slow on CPU. |

Accuracy of the current model is **not recorded anywhere in the repo**. The
training results live in `rased_training/` outside the repo
(`results.csv`, or run `yolo val`). Known training-pipeline issues: the merge
script splits by list order (validation comes almost entirely from the last
source), Roboflow augmented duplicates can leak across splits, and the
backbone was frozen.

---

## 5. Runtime behaviour worth knowing

- **Back-pressure, not a throttle.** The worker processes as fast as the
  phone allows; the newest frame always wins. A 15 FPS ceiling
  (`LiveCameraScreen.maxProcessFps`) stops fast phones from burning power for
  frames that add nothing (one frame per metre at 50 km/h).
- **Rotation.** Camera frames arrive in sensor orientation (landscape). The
  screen computes the clockwise rotation from `sensorOrientation` and the
  device orientation and sends it to the worker, so the model sees an upright
  road and the report photo is upright. The preview box follows the device
  orientation too.
- **Lifecycle.** Backgrounding stops the stream and pauses GPS; the worker
  stays alive and idle. Returning restarts the stream with no warm-up.
- **Startup.** `main.dart` starts the worker without awaiting it; the first
  screen appears immediately and the camera screen finds the model ready.
- **Bench harness.** Long-press the AI panel to cycle model asset × GPU/CPU
  preference; the 2-second line shows the effect. Do not long-press during a
  demo.

---

## 6. Diagnostics line (AI panel, every 2 s, also in logcat)

```
AI GPU | proc 11.5 fps (cam 29.8, drop 61%) | pre 9 set 1 inv 52 post 1 | total 63 rt 71 ms | jank 0/120 | 720x480 | score 0.41 boxes 1 | ep:active hit:180ms peak:0.38
```

| Field | Meaning |
|---|---|
| `GPU` / `CPU/XNNPACK-fp16 (4 thr)` / … | Backend the worker settled on |
| `proc` | Processed frames per second (the number that matters) |
| `cam`, `drop` | Camera frames per second and the share not processed (expected and fine) |
| `pre / set / inv / post` | Worker stage times in ms: sampling, tensor copy, inference, decode |
| `rt` | Camera callback → result on the UI isolate |
| `jank a/b` | UI frames over 16.7 ms out of all UI frames in the window; should be ~0 |
| `score`, `boxes` | Best confidence (even below threshold) and box count of the last frame |
| `ep`, `hit`, `peak` | Trigger policy state |

---

## 7. Configuration knobs

| What | Where |
|---|---|
| Model asset, bench list, worker confidence (0.20), IoU | `TFLiteService` constants |
| GPU preference, NNAPI flag, CPU FP16, GPU partitions | `TFLiteService` fields (runtime, via `restart()`) |
| FPS ceiling | `LiveCameraScreen.maxProcessFps` |
| Trigger gates | `ReportTriggerPolicy` constructor defaults |
| Dedupe radius, recent-fix count, min report interval, look-ahead | `LiveCameraScreen` constants |
| UI box threshold | `LiveCameraScreen._uiConfidenceThreshold` |
| JPEG quality | `SnapshotMsg.jpegQuality` (default 80) |
| Camera resolution / format | `LiveCameraScreen._initializeCameraAndAI` (medium, YUV420) |

---

## 8. Device requirements

| | Minimum (≈8–10 FPS on CPU) | Recommended (15 FPS, no throttling) |
|---|---|---|
| Android | 10 | 12+ |
| Chipset | Snapdragon 665/680, Helio G85/G88, Exynos 850 class | Snapdragon 7-series, Dimensity 1080+, Exynos 1280+ |
| RAM | 4 GB | 6 GB+ |
| GPU | Adreno 610 / Mali-G52 with OpenCL (else CPU path, use the 320 or int8 model) | Adreno 644+ / Mali-G68+ |
| Camera | 720×480 stream at 30 FPS | plus OIS |
| Power | On a car charger; 4–6 W continuous | 4500 mAh+, out of direct sun |

Cortex-A53-only phones (e.g. Helio P22) have no FP16 arithmetic and land at
3–6 FPS; they are below the bar.

---

## 9. Testing

Unit tests (pure Dart, no device, no Flutter engine):

```
dart test test/frame_sampler_test.dart test/report_trigger_policy_test.dart
```

Static analysis: `flutter analyze` (changed files are lint-clean; a few
pre-existing info-level lints remain in untouched screens).

On-device protocol (see the roadmap for acceptance criteria): release APK,
read the AI panel line for backend and FPS, trigger one report and confirm the
photo is upright, then a fixed route with known potholes while collecting
`episodes.jsonl`.

---

## 10. Unverified on device (as of 2026-09-24)

These are designed for and expected to work, but no phone has run this code:

- GPU delegate acceptance on target chipsets (fallback chain covers failure).
- Whether XNNPACK FP16 engages (panel shows `CPU/XNNPACK-fp16` when it does).
- The rotation sign (`sensor − device`) for the back camera. The first report
  photo confirms it; if it is rotated, fix `_updateRotation` in the screen.
- Actual FPS numbers; the ranges in this document are estimates.
- The Gradle `noCompress "tflite"` block.

Known gaps carried over from the original app: nothing ever drains
`OfflineQueue`; the app holds no wakelock so a screen timeout pauses
detection; `applicationId` is still `com.example.tareeqi` and release builds
are signed with the debug key; the API base URL is a constant in
`ApiService`.
