# AI accuracy roadmap — pothole detector

Companion to [live-detection.md](live-detection.md) (how the pipeline works)
and [production-roadmap.md](production-roadmap.md) (app and operations). This
document is the ML engineer's plan: how to know the model's real accuracy on
our roads, and how to raise it release after release.

Guiding principle: **data and measurement first, architecture last.** The
current model was trained on other countries' roads from mixed camera angles
and evaluated on a validation split that, because of a script bug, comes
almost entirely from one source. Every gain below is easier to get, and to
prove, than switching model families.

---

## 0. Where we are (2026-09-24)

| Item | State |
|---|---|
| Model | YOLO26n, 1 class (`pothole`), `imgsz=640`, 150 epochs, patience 30, backbone frozen (`freeze=10`), trained from `yolo26n.pt` (`YoloModel/train_yolo26.py`) |
| Data | `YoloModel/merge_datasets.py` merges Roboflow sets (current project ~660 images, smartathon Saudi roads, aegis ~1,482, pothole-vhmow). RDD2022 and the Kaggle Rome set are configured with different relative paths and were probably skipped. Split 80/15/5 **by list order** (see 1.1). |
| Recorded accuracy | None in the repo. Training output lives in `rased_training/` outside the repo. |
| Inference context | Dashboard-mounted phone, 720×480 frames letterboxed to the model input (416 planned), 2×2 luma box filter, upright rotation, temporal episode policy (hit ≥ 0.30, peak ≥ 0.45). |
| What "accuracy" means for the product | Fraction of real potholes on a route that produce a report; false reports per km of clean road; GPS error of the pin. Not mAP. |

---

## 1. Milestone A — Measure honestly (week 1–2)

Nothing below can be judged without this.

| # | Task | Output |
|---|---|---|
| 1.1 | **Fix the split.** In `merge_datasets.py`, shuffle with a fixed seed and stratify by source before splitting, so train/val/test each contain every source. Today `split_index(idx, total)` walks the concatenated list, so val/test are the tail of the last source. | Regenerated dataset; per-source counts per split printed. |
| 1.2 | **Deduplicate.** Roboflow exports contain augmented copies (flips, crops, brightness) of the same photo; re-splitting puts copies on both sides and inflates mAP. Hash images (perceptual hash, e.g. pHash with Hamming ≤ 6) and keep one copy, or keep Roboflow's own `train/valid/test` folders and only remap labels. | Duplicate count and the dedupe policy recorded. |
| 1.3 | **Recover the baseline numbers** from `rased_training/rased_yolo26/v1_yolo26n/results.csv` (or `yolo val model=best.pt data=... imgsz=640`) *on the fixed split*. | mAP50, mAP50-95, P, R at conf 0.30 and 0.45, written into this file. |
| 1.4 | **Build the field regression set.** 200–300 frames from our own phones on our roads (the app saves the trigger JPEG for every report; add a debug switch to also save uncertain episodes). Cover day, dusk, night, wet road, shadows, small/far potholes, and ~30 % frames with no pothole but with manholes, patches, tar seams, speed bumps. Label carefully, freeze it, never train on it. | `rased_training/regression/` with `data.yaml`; a script `YoloModel/eval_regression.py` that prints recall, precision, false positives per frame at the app thresholds, per box-size bucket. |
| 1.5 | **Export parity check.** Run the same 20 regression images through PyTorch `best.pt` and the exported `.tflite` (float and int8) with the app's exact preprocessing; compare boxes and scores. | `YoloModel/parity_check.py`; max score delta and IoU recorded per export. Catches wrong letterbox, channel order, quantisation damage. |

Exit: a baseline row in the table in section 6, measured on data we trust.

---

## 2. Milestone B — Domain data (weeks 2–6, continuous afterwards)

The single largest lever. The detector has never seen Jordanian asphalt,
our lighting, or a dashboard camera at 1.2 m height.

| # | Task | Target |
|---|---|---|
| 2.1 | **Frame harvesting from drives.** Record 1080p video on the fleet phones during normal routes; extract frames at 1–2 FPS; also collect the app's trigger JPEGs and uncertain-episode JPEGs (peak 0.30–0.45). | 3,000+ candidate frames per month. |
| 2.2 | **Labelling.** CVAT or Roboflow; one class for now. Guidelines: tight boxes around the pothole rim; label every visible pothole including small/far ones (≥ 12 px wide at 720); do not label patches, manhole covers, cracks, wet spots. Two-person review on 10 % of frames; measure agreement. | 1,500 labelled frames / ~3,000 instances in the first round. |
| 2.3 | **Hard negatives.** 15–20 % of the set are frames with zero potholes but with the things the model confuses: manhole covers, asphalt patches, shadows, puddles, tar lines, speed bumps, road paint, gravel. Empty label files are valid YOLO negatives. | False positives on the regression set drop measurably. |
| 2.4 | **Conditions coverage.** Track per-condition counts (day/dusk/night, dry/wet, sun angle, speed). Aim for no condition under 10 % of the set. | Coverage table kept in `rased_training/DATASET.md`. |
| 2.5 | **Keep the public sets, weight the local set.** Public data helps generalisation; local data fixes the domain. Oversample local frames ×2–3 during training (duplicate entries in the train list) rather than dropping public data. | Ablation: public-only vs public+local vs local-weighted, on the regression set. |

---

## 3. Milestone C — Training recipe (weeks 4–8)

Changes to `YoloModel/train_yolo26.py`, each accepted or rejected on the
regression set, not on training-set mAP.

| # | Change | Rationale |
|---|---|---|
| 3.1 | **Train at the inference size.** `imgsz=416` (or multi-scale 352–480) to match the phone. A model trained at 640 and run at 416 loses small potholes it never saw at that scale. | Direct accuracy at the shipped resolution. |
| 3.2 | **Unfreeze the backbone.** `freeze=None`. Freezing 10 layers was right for a few hundred images; with several thousand it caps accuracy. Use a lower initial LR (`lr0=0.002`) for the fine-tune from the current `best.pt`. | Typically +2–5 mAP50 on domain data. |
| 3.3 | **Augmentation for a forward-facing dashcam.** Keep mosaic and HSV jitter; `fliplr=0.5` is fine; `flipud=0.0` (roads are never upside down); modest `scale=0.5`, `translate=0.1`; small `perspective`; `mixup=0.05`; `close_mosaic=15`. Add motion-blur and low-light augmentation (Albumentations) for speed and night. | Robustness to the real capture conditions. |
| 3.4 | **Longer, gentler schedule.** 200 epochs, cosine LR, patience 50, EMA on (default). Save the checkpoint with the best *regression-set recall at fixed false-positive rate*, not best val mAP, by running `eval_regression.py` in a callback or after each `save_period`. | Selects the model the product actually wants. |
| 3.5 | **Loss weighting for small objects.** Try `box=10` (from 7.5) and check small-box recall in the regression buckets; potholes at 15–25 m are small. | Recall at distance. |
| 3.6 | **Model size sweep.** yolo26n (baseline) → yolo26s at 416. Measure on device (bench harness) and on the regression set; ship s only if GPU phones keep ≥ 15 FPS and recall improves. Consider n at 480 vs s at 416 as alternatives. | Accuracy per millisecond. |
| 3.7 | **Distillation (later).** Train yolo26m/l on all data as a teacher; distil to n/s. Usually +1–3 mAP for the same runtime. | Free accuracy once the data is stable. |

---

## 4. Milestone D — Accuracy at the edge (parallel with C)

The model is only part of the reported accuracy. These live in the app.

| # | Task | Where |
|---|---|---|
| 4.1 | **Threshold tuning from field data.** Use `episodes.jsonl` plus the trigger photos to build a PR curve of *episodes* (not boxes). Choose `tPeak` for the false-report budget and `tHit` for continuity. Re-tune after every model change. | `ReportTriggerPolicy` defaults |
| 4.2 | **Quantisation check.** If the int8 export ships for CPU-only phones, measure its regression recall against fp32; accept ≤ 2 points drop, otherwise use W8A16 or fp16-XNNPACK instead. | `parity_check.py`, `eval_regression.py` |
| 4.3 | **Preprocessing fidelity.** Verify on device that the model input looks like training input: `FrameSampler.toRgb()` dumped to a JPEG once (debug menu) — orientation, colour, letterbox. The box filter should stay on for 720→416. | `frame_sampler.dart` |
| 4.4 | **Camera settings.** Fixed exposure compensation at night if the road is underexposed; check whether `ResolutionPreset.high` (1280×720 → 416) improves small-pothole recall enough to pay for the extra copy cost. | `live_camera_screen.dart` |
| 4.5 | **GPS accuracy as part of "accuracy".** Calibrate the 12 m look-ahead from `speed × tEndFromTrig`; report median pin error on the test route; consider the late-firing photo mode if photos are small. | roadmap Phase 1 |
| 4.6 | **Per-device recall.** Same route, each fleet phone class; if a CPU-only class loses recall at 320, that class gets int8 at 416 rather than fp32 at 320. | bench harness |

---

## 5. Milestone E — Continuous improvement loop (monthly, from month 2)

```
drive ─▶ episodes.jsonl + trigger JPEGs + uncertain JPEGs
      ─▶ label the uncertain and the false reports (active learning)
      ─▶ add to train set (never to the regression set)
      ─▶ retrain (recipe C) ─▶ eval_regression.py ─▶ parity_check.py
      ─▶ export E2 fp32 + int8, write model.json (version, imgsz, layout,
          thresholds, regression numbers)
      ─▶ bench on device classes ─▶ ship via model download (roadmap 4.4)
      ─▶ monitor score distributions and reports/km per device (drift)
```

Rules for the loop:

- The regression set is frozen; extend it only by adding new frames with a
  new version number, and report numbers on both old and new versions.
- A model ships only if it is not worse on any regression bucket (size,
  lighting) by more than 1 point and better overall.
- Every shipped model has a `model.json` next to it and its numbers in the
  table below.
- Uncertain-episode capture in the app is the data engine; keep it available
  behind a debug/remote-config switch even in production builds.

---

## 6. Targets and tracking

Fill this table as milestones complete. Numbers are on the frozen field
regression set unless noted.

| Milestone | Model | imgsz | Recall @ app thresholds | False positives / 100 clean frames | Route recall (field) | False reports / km | Device FPS (A25) |
|---|---|---|---|---|---|---|---|
| Baseline (A) | yolo26n v1, frozen backbone | 640 | ? | ? | ? | ? | ? |
| B + C first retrain | yolo26n v2, local data, unfrozen | 416 | ≥ 0.80 | ≤ 5 | ≥ 0.80 | ≤ 0.5 | 15 (cap) |
| C model sweep | yolo26s v3 (if FPS allows) | 416 | ≥ 0.88 | ≤ 3 | ≥ 0.85 | ≤ 0.3 | ≥ 15 GPU |
| E, after 3 loops | v4+ | 416/480 | ≥ 0.92 | ≤ 2 | ≥ 0.90 | ≤ 0.2 | ≥ 15 GPU |

Recall buckets to report alongside: box width < 24 px / 24–48 px / > 48 px at
the model input; day / night; dry / wet.

---

## 7. Tooling to add in `YoloModel/`

| Script | Purpose |
|---|---|
| `audit_dataset.py` | Per-source and per-split counts, duplicate detection (pHash), label sanity (empty files, boxes out of range, tiny boxes), class-map check. |
| `eval_regression.py` | Recall / precision / FP-per-frame at fixed thresholds, per size and condition bucket; writes a JSON summary for the table above. |
| `parity_check.py` | PyTorch vs `.tflite` (fp32/int8) on the same images with the app's preprocessing; reports score and IoU deltas. |
| `select_uncertain.py` | Pulls uncertain/false-report episodes from `episodes.jsonl` + JPEGs into a labelling batch. |
| `make_model_json.py` | Writes `model.json` (version, imgsz, layout, thresholds, regression numbers) next to an export. |

---

## 8. Things not to do yet

- Switching to a transformer detector (RT-DETR class): 3–5× the compute for
  little gain at this data size; the phones cannot afford it.
- Multi-class (cracks, manholes) before there are ≥ 500 local labelled
  instances per class; it dilutes the pothole head and today's data has
  almost none.
- Per-object tracking in the app before field logs show several potholes per
  frame is common.
- Tuning thresholds on training-set metrics. Only the regression set and the
  episode log count.
