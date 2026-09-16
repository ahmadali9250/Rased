import argparse
from pathlib import Path

from ultralytics import YOLO

# ==============================================================
# CONFIG
# ==============================================================

DATA_YAML = "../rased_training/merged_dataset/data.yaml"  # ناتج merge_datasets.py (شغّلناه من YoloModel)
PROJECT_NAME = "../rased_training/rased_yolo26"  # يطلع جوا rased_training مش جوا YoloModel نفسها
RUN_NAME = "v1_yolo26n"

BASE_MODEL = "yolo26n.pt"  # أوزان مدرّبة مسبقاً — نانو
IMGSZ = 640
EPOCHS = 150
PATIENCE = 30
SAVE_PERIOD = 10  # checkpoint كل 10 epochs

# فعّلوا هاي لو عدد صوركم المحلية المضافة أقل من ~500 للفئة الواحدة
FREEZE_BACKBONE_LAYERS = 10  # حطوها None لو ما بدكم freeze


def main(resume: bool):
    weights_dir = Path(PROJECT_NAME) / RUN_NAME / "weights"
    last_ckpt = weights_dir / "last.pt"

    if resume and last_ckpt.exists():
        print(f"▶️  استكمال التدريب من: {last_ckpt}")
        model = YOLO(str(last_ckpt))
        model.train(resume=True)
        return

    print("=" * 60)
    print(f"🚀 بدء تدريب {BASE_MODEL} على {DATA_YAML}")
    print(f"   Epochs={EPOCHS} | imgsz={IMGSZ} | freeze={FREEZE_BACKBONE_LAYERS}")
    print("=" * 60)

    model = YOLO(BASE_MODEL)

    model.train(
        data=DATA_YAML,
        project=PROJECT_NAME,
        name=RUN_NAME,
        epochs=EPOCHS,
        imgsz=IMGSZ,
        batch=-1,          # auto-batch — بيحسب حسب VRAM المتاح فعلياً وقت التشغيل
        amp=True,           # mixed precision — RTX 3070 (Ampere) بتستفيد منها
        device=0,
        workers=6,           # عندك 8 threads، خلي 1-2 حرين للنظام
        cache="disk",        # مش "ram" — الداتا سيت المدموج غالباً أكبر من الرام المتاح
        patience=PATIENCE,
        save_period=SAVE_PERIOD,
        close_mosaic=10,
        freeze=FREEZE_BACKBONE_LAYERS,
        exist_ok=True,
    )

    print("\n✅ التدريب انتهى. أفضل نموذج:")
    print(f"   {weights_dir / 'best.pt'}")
    print("\n▶️  الخطوة التالية: شغّل export_model.py على هالملف")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--resume", action="store_true", help="استكمال من آخر checkpoint محفوظ")
    args = parser.parse_args()
    main(resume=args.resume)