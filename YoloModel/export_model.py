"""
export_model.py
================
يصدّر نسخ LiteRT (.tflite) من best.pt لمقارنتها فعلياً على الهاتف.

الاسم الموحّد للملفات (التطبيق يعتمد عليه):
    pothole_yolo26n_<imgsz>_<precision>[_raw].tflite

المصفوفة (راجع الخطة في التطبيق — TFLiteService.benchModelAssets):

  E1  416 e2e   fp32   pothole_yolo26n_416_fp32.tflite
      نفس شكل المخرج الحالي [1, 300, 6] — بدون أي تغيير بالـ parser.
      ذيل top-k (TOPK_V2/GATHER/CAST) غالباً يبقى على CPU مع GPU delegate.

  E2  416 raw   fp32   pothole_yolo26n_416_fp32_raw.tflite   ← المرشّح الأول للشحن
      رأس one-to-one مع حذف الـ postprocess → [1, anchors, 4+nc]
      (xyxy بالبكسل + درجات الفئات). كل الـ graph مدعوم على GPU، وبدون NMS:
      YOLO26 يعطي صندوقاً واحداً لكل جسم، فيكفي فلتر ثقة (+ NMS خفيف احتياطي).

  E3  320 raw   fp32   pothole_yolo26n_320_fp32_raw.tflite
      احتياط للأجهزة الضعيفة (Snapdragon 6xx) إذا 416 ما وصلت ≥ 8 FPS.

  E4  416 raw   int8   pothole_yolo26n_416_int8_raw.tflite
      تكميم PTQ كامل بمعايرة — للأجهزة التي تعمل على CPU فقط (XNNPACK int8
      أسرع 1.5–2.5×). لا يفيد مسار GPU (الـ GPU يفكّ التكميم).

  E5  640 e2e   fp32   pothole_yolo26n_640_fp32.tflite
      الأساس الحالي — للمقارنة بالدقة فقط، بطيء جداً على CPU.

ملاحظات مهمة:
  * YOLO26 بدون NMS أصلاً (NMS-free). nms=False *لا* يعطي المخرج الخام
    [1, nc+4, N] كما كان مكتوباً هنا سابقاً؛ رأس end-to-end يمرّ عبر
    Detect.postprocess (top-k) ويعطي [1, max_det, 6]. للحصول على raw
    نُعطّل postprocess نفسه (انظر _strip_postprocess).
  * format="litert" (ai-edge-torch) يحافظ على NCHW [1,3,H,W].
    format="tflite" (onnx2tf) يعطي NHWC [1,H,W,3] وهو أنسب لـ GPU delegate.
    التطبيق يدعم الاثنين تلقائياً. نجرب "tflite" أولاً ونرجع لـ "litert"
    إذا لم تتوفر أدوات onnx2tf.
  * QAT غير مدعوم لـ litert في Ultralytics الحالي؛ INT8 = PTQ وقت التصدير.
  * بعد التصدير افحص كل ملف بـ:  python ../assets/check_model.py <file>
    (يطبع الشكل، العمليات غير المدعومة على GPU، وزمن invoke).

الاستخدام:
    python export_model.py            # كل المصفوفة
    python export_model.py E2 E3      # مجموعة فرعية
    python export_model.py --val      # + تقييم mAP عند 640/416/320
"""

from __future__ import annotations

import shutil
import sys
from pathlib import Path

from ultralytics import YOLO

BEST_PT = "../rased_training/rased_yolo26/v1_yolo26n/weights/best.pt"
DATA_YAML = "../rased_training/merged_dataset/data.yaml"
OUTPUT_DIR = Path("./exported_models")
ARCH = "yolo26n"

# (name, imgsz, raw, precision)
MATRIX: dict[str, tuple[int, bool, str]] = {
    "E1": (416, False, "fp32"),
    "E2": (416, True, "fp32"),
    "E3": (320, True, "fp32"),
    "E4": (416, True, "int8"),
    "E5": (640, False, "fp32"),
}


def _target_name(imgsz: int, raw: bool, precision: str) -> str:
    suffix = "_raw" if raw else ""
    return f"pothole_{ARCH}_{imgsz}_{precision}{suffix}.tflite"


def _strip_postprocess() -> None:
    """يجعل Detect.postprocess هوية: المخرج يصبح [1, anchors, 4+nc]
    (xyxy بالبكسل + درجات sigmoid) بدون TOPK/GATHER/CAST."""
    from ultralytics.nn.modules import head

    head.Detect.postprocess = staticmethod(lambda preds, max_det, nc=80: preds)
    print("   ↳ Detect.postprocess = identity (raw one-to-one output)")


def _export(imgsz: int, raw: bool, precision: str) -> Path:
    target = OUTPUT_DIR / _target_name(imgsz, raw, precision)
    print(f"\n📦 {target.name}  (imgsz={imgsz}, raw={raw}, {precision})")

    model = YOLO(BEST_PT)
    if raw:
        _strip_postprocess()

    exported: str | None = None
    # NHWC عبر onnx2tf أولاً (أفضل لـ GPU delegate)، ثم litert (NCHW).
    for fmt in ("tflite", "litert"):
        kwargs: dict = {"imgsz": imgsz, "nms": False}
        if precision == "int8":
            # tflite (onnx2tf): int8=True + data ; litert (ai-edge-torch): quantize=8 + data
            if fmt == "tflite":
                kwargs.update(int8=True, data=DATA_YAML)
            else:
                kwargs.update(quantize=8, data=DATA_YAML)
        elif precision == "fp16":
            kwargs.update(half=True)
        try:
            print(f"   → format={fmt}")
            exported = model.export(format=fmt, **kwargs)
            break
        except Exception as e:  # noqa: BLE001 — نجرب الصيغة التالية
            print(f"   ⚠️ format={fmt} فشل: {type(e).__name__}: {e}")
    if exported is None:
        raise RuntimeError(f"تعذّر تصدير {target.name} بأي صيغة")

    exported_path = Path(exported)
    if exported_path.is_dir():
        # onnx2tf يعطي مجلد saved_model مع ملفات .tflite بداخله
        candidates = sorted(exported_path.glob("*.tflite"))
        wanted = [c for c in candidates if precision in c.name.lower()] or candidates
        if not wanted:
            raise RuntimeError(f"لا يوجد .tflite داخل {exported_path}")
        exported_path = wanted[0]

    OUTPUT_DIR.mkdir(exist_ok=True)
    shutil.copyfile(exported_path, target)
    print(f"   ✅ {target}  ({target.stat().st_size / 1e6:.1f} MB)")
    return target


def _validate(sizes=(640, 416, 320)) -> None:
    print("\n📊 تقييم mAP على مجموعة التحقق لكل حجم إدخال:")
    for s in sizes:
        model = YOLO(BEST_PT)
        metrics = model.val(data=DATA_YAML, imgsz=s, verbose=False)
        print(
            f"   imgsz={s}: mAP50={metrics.box.map50:.3f}  "
            f"mAP50-95={metrics.box.map:.3f}"
        )
    print(
        "   ↳ إذا الهبوط عند 416 غير مقبول: fine-tune best.pt ~20 epoch بـ "
        "imgsz=416 (train_yolo26.py) — موديل مدرَّب على حجم الاستدلال أدق."
    )


if __name__ == "__main__":
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    flags = {a for a in sys.argv[1:] if a.startswith("--")}
    selected = args or list(MATRIX)

    produced: list[Path] = []
    for key in selected:
        if key not in MATRIX:
            print(f"⚠️ تجاهل {key}: غير معروف. المتاح: {', '.join(MATRIX)}")
            continue
        imgsz, raw, precision = MATRIX[key]
        try:
            produced.append(_export(imgsz, raw, precision))
        except Exception as e:  # noqa: BLE001
            print(f"   ❌ {key} فشل: {e}")

    if "--val" in flags:
        _validate()

    print("\n" + "=" * 64)
    print("✅ الملفات الجاهزة — انسخ ما تريد تجربته إلى assets/ بالتطبيق:")
    for p in produced:
        print(f"   {p}")
    print("=" * 64)
    print("\nخطوات بالتطبيق لكل ملف تجرّبه:")
    print("  1) python ../assets/check_model.py <file>   ← شكل المخرج + العمليات + الزمن")
    print("  2) أضفه إلى pubspec.yaml (flutter: assets:) وإلى")
    print("     TFLiteService.benchModelAssets، ثم long-press على لوحة AI بالكاميرا")
    print("     للتبديل بين الموديلات و GPU/CPU وقراءة سطر الأداء كل ثانيتين.")
    print("  3) عند اختيار الفائز: اجعله TFLiteService.defaultModelAsset واحذف البقية.")
