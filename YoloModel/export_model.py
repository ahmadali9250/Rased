"""
export_model.py
================
يصدّر 3 نسخ لـ LiteRT (.tflite) للمقارنة بينهم فعلياً على التطبيق:

  1) FP32       (best_fp32.tflite)   — الأساس، بيشتغل FP16 تلقائياً وقت التشغيل لو GPU delegate شغال
  2) w8a32 INT8 (best_w8a32.tflite)  — تكميم ديناميكي (أوزان بس)، بدون داتا سيت معايرة، وسط بالسرعة/الدقة
  3) INT8 ثابت  (best_int8.tflite)   — تكميم PTQ مباشر (بمعايرة data=)، الأسرع والأصغر

⚠️ تصحيح مهم: ما في QAT (quantize=8 أثناء model.train) هون — QAT بصيغة Ultralytics الحالية
   مدعوم بس لصادرات onnx و engine (TensorRT)، ومرفوض تماماً لـ litert (AssertionError صريح
   بكود Ultralytics نفسه). INT8 لـ litert بيصير حصراً عبر PTQ مباشر وقت التصدير (quantize=8 + data=)
   من best.pt الأصلي مباشرة، بدون أي خطوة تدريب إضافية قبله.

⚠️ ملاحظة سابقة لسا صحيحة: ما في "float16.tflite" منفصل بصيغة litert — أي FP32 export بيشتغل
   تلقائياً بدقة FP16 وقت التشغيل عبر GPU delegate (WebGPU/OpenCL/Metal).
   (quantize لـ litert بيقبل بس: 8, 'w8a16', 'w8a32', أو None/32 — مو 16)

مهم جداً: nms=False → الموديل رح يرجّع output جاهز بشكل (1, 300, 6)
[x1, y1, x2, y2, confidence, class_id] بدل الشكل الخام (1, nc+4, 8400).
هاد بيلغي الحاجة للـ NMS اليدوي بـ Dart بالكامل — لازم يترافق مع تحديث tflite_service.dart.
"""

from pathlib import Path

from ultralytics import YOLO

BEST_PT = "../rased_training/rased_yolo26/v1_yolo26n/weights/best.pt"
DATA_YAML = "../rased_training/merged_dataset/data.yaml"
IMGSZ = 640
OUTPUT_DIR = Path("./exported_models")
OUTPUT_DIR.mkdir(exist_ok=True)


def export_fp32():
    print("📦 تصدير FP32 (بدون تكميم — بيشتغل FP16 تلقائياً على GPU delegate)...")
    model = YOLO(BEST_PT)
    path = model.export(
        format="litert",
        imgsz=IMGSZ,
        quantize=None,  # FP32 — القيمة الافتراضية لـ litert
        nms=False,      # output جاهز (1,300,6) بدون NMS يدوي بالتطبيق
    )
    print(f"   ✅ {path}")
    return path


def export_w8a32_dynamic():
    print("\n📦 تصدير w8a32 (INT8 ديناميكي — أوزان بس، بدون معايرة)...")
    model = YOLO(BEST_PT)
    path = model.export(
        format="litert",
        imgsz=IMGSZ,
        quantize="w8a32",  # INT8 أوزان + FP32 activations، ما بيحتاج data= للمعايرة
        nms=False,
    )
    print(f"   ✅ {path}")
    return path


def export_int8_static():
    print("\n📦 تصدير INT8 ثابت (PTQ مباشر بمعايرة — بدون QAT)...")
    model = YOLO(BEST_PT)  # نفس best.pt الأصلي — بدون أي تدريب إضافي قبله
    path = model.export(
        format="litert",
        imgsz=IMGSZ,
        quantize=8,
        data=DATA_YAML,  # للمعايرة (calibration) — إلزامي لـ static INT8
        nms=False,
    )
    print(f"   ✅ {path}")
    return path


if __name__ == "__main__":
    fp32_path = export_fp32()
    w8a32_path = export_w8a32_dynamic()
    int8_path = export_int8_static()

    print("\n" + "=" * 60)
    print("✅ الملفات الثلاث جاهزة للمقارنة — انسخوا اللي بدكم تجربوه لـ assets/ بالتطبيق:")
    print(f"   {fp32_path}   →  assets/best_fp32.tflite   (الأدق، الأثقل)")
    print(f"   {w8a32_path}  →  assets/best_w8a32.tflite  (وسط)")
    print(f"   {int8_path}   →  assets/best_int8.tflite   (الأسرع — توقعنا نستخدم هاد بالنهاية)")
    print("=" * 60)
    print("\n⚠️  قبل ما تنسخوا أي وحدة: تأكدوا من شكل الـ output tensor (لازم (1, 300, 6)):")
    print("    from ultralytics import YOLO")
    print(f"    m = YOLO('{int8_path}')")
    print("    print(m.model.overrides)  # أو افحصوا بـ TFLite interpreter مباشرة")
    print("\n📝 تذكير: tflite_service.dart فيه _modelAsset مكتوب 'assets/best_int8.tflite' ثابت —")
    print("    لو بدك تجرب fp32 أو w8a32 بالتطبيق فعلياً، غيّر هاد السطر مؤقتاً.")