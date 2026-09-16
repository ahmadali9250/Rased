"""
export_model.py
================
يصدّر 3 نسخ لـ LiteRT (.tflite) للمقارنة بينهم فعلياً على التطبيق:

  1) FP32       (best_fp32.tflite)   — الأساس، بيشتغل FP16 تلقائياً وقت التشغيل لو GPU delegate شغال
  2) w8a32 INT8 (best_w8a32.tflite)  — تكميم ديناميكي (أوزان بس)، بدون داتا سيت معايرة، وسط بالسرعة/الدقة
  3) INT8 ثابت  (best_int8.tflite)   — بعد QAT fine-tune، الأسرع والأصغر — هاد المفروض يكون نسخة الإنتاج النهائية

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


def qat_finetune_and_export_int8():
    print("\n🎯 مرحلة QAT (Quantization-Aware Training)...")
    model = YOLO(BEST_PT)

    # fine-tune قصير جداً بـ learning rate منخفض — الهدف تكيّف الأوزان مع INT8 مش تعلّم من جديد
    model.train(
        data=DATA_YAML,
        quantize=8,
        epochs=5,
        batch=32,
        imgsz=IMGSZ,
        optimizer="AdamW",
        lr0=0.00001,
        lrf=0.1,
        warmup_epochs=0.5,
        cos_lr=True,
        mosaic=0.0,
        project="../rased_training/rased_yolo26",
        name="v1_yolo26n_qat",
        exist_ok=True,
    )

    qat_weights = "../rased_training/rased_yolo26/v1_yolo26n_qat/weights/best.pt"
    print(f"\n📦 تصدير INT8 ثابت (بعد QAT) من: {qat_weights}")
    qat_model = YOLO(qat_weights)
    path = qat_model.export(
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
    int8_path = qat_finetune_and_export_int8()

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