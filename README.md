# Rased | راصد

**Rased** is an on-device AI dashcam app built with Flutter. Mounted on the
dashboard, it watches the road, detects potholes in real time with a YOLO26n
model running locally (LiteRT / TensorFlow Lite), and reports each confirmed
pothole once — photo plus GPS — to the municipal backend, without the driver
touching the phone.

Documentation:

- [docs/live-detection.md](docs/live-detection.md) — how the live detection
  pipeline works today: architecture, model, trigger policy, diagnostics,
  device requirements, what is still unverified on a phone.
- [docs/production-roadmap.md](docs/production-roadmap.md) — what remains to
  make it production ready, in order, with exit criteria.
- [docs/ai-accuracy-roadmap.md](docs/ai-accuracy-roadmap.md) — the ML plan:
  measuring real accuracy, local data collection, training recipe, edge
  tuning, and the monthly improvement loop.

---

## Key features

- **Live detection off the UI thread.** All per-frame work (colour
  conversion, inference, JPEG encoding) runs in a dedicated worker isolate.
  The preview stays smooth regardless of phone speed. Backend selection is
  GPU → CPU/XNNPACK (FP16) → CPU, chosen and verified at start-up.
- **One report per pothole.** A time-based episode policy confirms a pothole
  over ~300 ms of detections and fires once; spatial dedupe stops repeats on
  return legs or in traffic.
- **Reports never pause detection.** Photo from the detection frame, GPS from
  a continuous stream, uploads through a background queue with offline
  fallback.
- **On-device diagnostics.** The AI panel shows backend, processed FPS,
  per-stage timings and UI jank every two seconds; a per-episode log on the
  phone supports threshold tuning from real drives.
- **Manual reporting** with local AI pre-check, bilingual (Arabic/English)
  dark UI, map and admin screens, role-based backend.

## Tech stack

- Flutter / Dart (Dart ≥ 3.11)
- `tflite_flutter` 0.12 (LiteRT), `camera` (camerax), `geolocator`, `image`,
  `path_provider`, `http`, `shared_preferences`
- Model: YOLO26n exported to `.tflite` (see `YoloModel/`)

## Getting started

Prerequisites: Flutter SDK (stable), Android SDK / Android Studio, a physical
Android phone (camera and GPU are required for anything meaningful).

```bash
flutter pub get
flutter analyze
dart test test/frame_sampler_test.dart test/report_trigger_policy_test.dart
flutter build apk --release --split-per-abi   # or: flutter run --profile
```

Install `build/app/outputs/flutter-apk/app-arm64-v8a-release.apk`. Always
measure with release or profile builds; debug builds are several times slower
in the pixel loops.

Windows note: Smart App Control may block Flutter's shader compiler
(`impellerc.exe`). Add an exclusion for the Flutter SDK folder before
`flutter test`, `flutter run` or `flutter build`.

### Model file

The model ships in `assets/` with the naming convention
`pothole_<arch>_<imgsz>_<precision>[_raw].tflite` (currently
`pothole_yolo26n_640_fp32.tflite`). To try another export, add it to
`pubspec.yaml` under `flutter: assets:` and to
`TFLiteService.benchModelAssets`, then long-press the AI panel in the live
screen to switch between models and GPU/CPU at runtime. Export variants with
`YoloModel/export_model.py` and verify them with `assets/check_model.py`.

## Repository layout

```
lib/
  main.dart                          app start; pre-warms the AI worker
  screens/live_camera_screen.dart    dashcam screen: frame dispatch, trigger, UI
  services/detection_worker.dart     worker isolate: interpreter, decode, snapshot
  services/frame_sampler.dart        letterbox + rotation + YUV→RGB (pure Dart, tested)
  services/tflite_service.dart       main-isolate facade over the worker (singleton)
  services/report_trigger_policy.dart  when detections become a report (tested)
  services/report_upload_queue.dart  background uploads + offline fallback
  services/episode_log.dart          per-episode JSONL log for tuning
  services/api_service.dart          REST client (auth, hazards)
  widgets/bounding_box_painter.dart  draws boxes on the preview
test/                                pure-Dart unit tests (run with `dart test`)
YoloModel/                           dataset merge, training and export scripts
assets/                              model, classes.txt, check_model.py
docs/                                documentation
```

## Team

- **Frontend Engineer:** [Ahmad Ali](https://github.com/ahmadali9250)
- **AI / ML Engineer:** [Abdallah Abughallous](https://github.com/AbdaullahAG)
- **Backend Engineer:** [Abd Alqader Alsa'di](https://github.com/Abedalqaders)

## Privacy and permissions

- **Camera** — to scan the road and capture hazard photos.
- **Location (precise)** — to attach GPS coordinates to reports.
- **Storage (app-private)** — report photos awaiting upload, offline queue,
  diagnostics log.
