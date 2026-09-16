"""
export_model.py
================
1) يعمل fine-tuneQuantization-Aware Training (QAT) 
2) يصدّر نسختين لـ LiteRT (.tflite):
     - float16   (best_float16.tflite)  
     - int8 QAT  (best_int8.tflite)     

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


def export_float16():
    print("📦 تصدير float16 (بدون تكميم)...")
    model = YOLO(BEST_PT)
    path = model.export(
        format="litert",
        imgsz=IMGSZ,
        quantize=16,   # float16
        nms=False,     # output جاهز (1,300,6) بدون NMS يدوي بالتطبيق
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
    print(f"\n📦 تصدير int8 (بعد QAT) من: {qat_weights}")
    qat_model = YOLO(qat_weights)
    path = qat_model.export(
        format="litert",
        imgsz=IMGSZ,
        quantize=8,
        data=DATA_YAML,  # للمعايرة (calibration)
        nms=False,
    )
    print(f"   ✅ {path}")
    return path


if __name__ == "__main__":
    fp16_path = export_float16()
    int8_path = qat_finetune_and_export_int8()

    print("\n" + "=" * 60)
    print("✅ الملفات جاهزة — انسخوها لمجلد assets/ بالتطبيق:")
    print(f"   {fp16_path}  →  assets/best_float16.tflite")
    print(f"   {int8_path}  →  assets/best_int8.tflite")
    print("=" * 60)
    print("\n⚠️  قبل ما تنسخوا: افتحوا نموذج واحد بسرعة وتأكدوا من شكل الـ output tensor")
    print("    (لازم يطلع (1, 300, 6)) — عشان تتأكدوا إنه يطابق كود tflite_service.dart الجديد:")
    print("    from ultralytics import YOLO")
    print(f"    m = YOLO('{int8_path}')")
    print("    print(m.model.overrides)  # أو افحصوا بـ TFLite interpreter مباشرة")
    