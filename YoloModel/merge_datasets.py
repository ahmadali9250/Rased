
import shutil
import xml.etree.ElementTree as ET
from pathlib import Path

import yaml

# ==============================================================
# CONFIG 
# ==============================================================

OUTPUT_DIR = Path("../rased_training/merged_dataset")  

SOURCES = {
    # كل مصدر Roboflow (format="yolo") بيتعامل معه السكريبت تلقائياً بنفس الطريقة —
    "roboflow_current": {
        "path": Path("../rased_training/data_sources/roboflow_current"),  # الداتا سيت الحالي عندكم (660 صورة)
        "format": "yolo",

        "class_map": {
            "pothole": "pothole",
            "potholes": "pothole",
            "broken_manhole": "broken_manhole",
            "manhole": "broken_manhole",
            "crack": "crack",
        },
    },
    "roboflow_smartathon": {
        "path": Path("../rased_training/data_sources/roboflow_smartathon"),  # smartathon/new-pothole-detection (طرق سعودية)
        "format": "yolo",
        "class_map": {
            "pothole": "pothole",
            "potholes": "pothole",
            "Pothole": "pothole",
            "Potholes": "pothole",
            "pothole-10": "pothole",
            "bache": "pothole",
            "manhole": "broken_manhole",
        },
    },
    "roboflow_aegis": {
        "path": Path("../rased_training/data_sources/roboflow_aegis"),  # aegis/pothole-detection-i00zy (1,482 صورة)
        "format": "yolo",
        "class_map": {
            "pothole": "pothole",
            "Pothole": "pothole",
        },
    },
    "pothole-vhmow": {
        "path": Path("../rased_training/data_sources/pothole-vhmow"),  
        "format": "yolo",
        "class_map": {
            "pothole": "pothole",
        },
    },
    "rdd2022": {
        "path": Path("./data_sources/RDD2022/India"),  # أو China / United_States... إلخ
        "format": "voc",  # RDD2022 عادة PASCAL VOC XML
        "class_map": {
            "D40": "pothole",           # حفرة
            "D00": "crack",             # شرخ طولي
            "D10": "crack",             # شرخ عرضي
            "D20": "crack",             # شرخ تمساحي

        },
    },
    "kaggle_rome": {
        "path": Path("./data_sources/road-damage-dataset-potholes-cracks-and-manholes"),
        "format": "polygon",     
        "class_map": {
            "pothole": "pothole",
            "crack": "crack",
            "manhole": "broken_manhole",
        },
    },
}

# قرار: هذي الجولة حفر بس (pothole) — الثلاث مصادر المنزّلة فعلياً كلهم فئة وحدة بس أصلاً
# (تحقّقنا من data.yaml لكل واحد). broken_manhole وcrack بيرجعوا بجولة لاحقة لما تتجمع بيانات كفاية.
FINAL_CLASSES = ["pothole"]  # الترتيب هون = الترتيب اللي رح يطلع بالـ data.yaml
CLASS_TO_ID = {name: i for i, name in enumerate(FINAL_CLASSES)}

SPLIT_RATIOS = {"train": 0.8, "val": 0.15, "test": 0.05}


# ==============================================================
# Helpers
# ==============================================================

def ensure_dirs():
    for split in ("train", "val", "test"):
        (OUTPUT_DIR / split / "images").mkdir(parents=True, exist_ok=True)
        (OUTPUT_DIR / split / "labels").mkdir(parents=True, exist_ok=True)


def voc_to_yolo_line(xml_path: Path, class_map: dict) -> tuple[list[str], str | None]:
    """يحوّل ملف Pascal VOC XML (زي RDD2022) لأسطر YOLO txt، ويرجّع اسم الصورة."""
    tree = ET.parse(xml_path)
    root = tree.getroot()

    size = root.find("size")
    img_w = int(size.find("width").text)
    img_h = int(size.find("height").text)
    filename = root.find("filename").text

    lines = []
    for obj in root.findall("object"):
        cls_raw = obj.find("name").text.strip()
        if cls_raw not in class_map:
            continue
        unified_cls = class_map[cls_raw]
        if unified_cls not in CLASS_TO_ID:
            continue
        cls_id = CLASS_TO_ID[unified_cls]

        bbox = obj.find("bndbox")
        xmin = float(bbox.find("xmin").text)
        ymin = float(bbox.find("ymin").text)
        xmax = float(bbox.find("xmax").text)
        ymax = float(bbox.find("ymax").text)

        cx = ((xmin + xmax) / 2) / img_w
        cy = ((ymin + ymax) / 2) / img_h
        w = (xmax - xmin) / img_w
        h = (ymax - ymin) / img_h

        lines.append(f"{cls_id} {cx:.6f} {cy:.6f} {w:.6f} {h:.6f}")

    return lines, filename


def polygon_to_yolo_line(polygon_txt_path: Path, class_map: dict) -> list[str]:
    """
    يحوّل ملف annotation فيه مضلعات مطبّعة (زي داتا سيت Kaggle روما) لصندوق محيط (axis-aligned bbox).
    الصيغة المفترضة بكل سطر: class_name x1 y1 x2 y2 x3 y3 x4 y4 (قيم 0-1)
    ⚠️ تأكدوا من الصيغة الفعلية بفتح ملف عينة يدوياً — هاي أشيع صيغة لكن ممكن تختلف.
    """
    lines = []
    if not polygon_txt_path.exists():
        return lines

    with open(polygon_txt_path) as f:
        for raw in f:
            parts = raw.strip().split()
            if len(parts) < 9:
                continue
            cls_raw = parts[0]
            if cls_raw not in class_map:
                continue
            unified_cls = class_map[cls_raw]
            if unified_cls not in CLASS_TO_ID:
                continue
            cls_id = CLASS_TO_ID[unified_cls]

            coords = list(map(float, parts[1:9]))
            xs = coords[0::2]
            ys = coords[1::2]
            xmin, xmax = min(xs), max(xs)
            ymin, ymax = min(ys), max(ys)

            cx = (xmin + xmax) / 2
            cy = (ymin + ymax) / 2
            w = xmax - xmin
            h = ymax - ymin

            lines.append(f"{cls_id} {cx:.6f} {cy:.6f} {w:.6f} {h:.6f}")

    return lines


def remap_yolo_labels(label_path: Path, source_names: list[str], class_map: dict) -> list[str]:
    """يعيد ترقيم ملف YOLO txt جاهز (زي داتا سيت Roboflow) حسب الترتيب الموحّد الجديد."""
    if not label_path.exists():
        return []
    lines = []
    with open(label_path) as f:
        for raw in f:
            parts = raw.strip().split()
            if not parts:
                continue
            old_id = int(parts[0])
            if old_id >= len(source_names):
                continue
            old_name = source_names[old_id]
            if old_name not in class_map:
                continue
            unified_cls = class_map[old_name]
            if unified_cls not in CLASS_TO_ID:
                continue
            new_id = CLASS_TO_ID[unified_cls]
            lines.append(" ".join([str(new_id)] + parts[1:]))
    return lines


def split_index(idx: int, total: int) -> str:
    if idx < total * SPLIT_RATIOS["train"]:
        return "train"
    elif idx < total * (SPLIT_RATIOS["train"] + SPLIT_RATIOS["val"]):
        return "val"
    return "test"


# ==============================================================
# Main
# ==============================================================

def process_roboflow_source(cfg: dict):
    """يقرأ data.yaml الأصلي عشان يعرف ترتيب الأسماء الحقيقي، ويعيد ترقيم كل label."""
    src = cfg["path"]
    data_yaml_path = src / "data.yaml"
    if not data_yaml_path.exists():
        print(f"⚠️  data.yaml مش موجود بـ {src} — تخطي المصدر")
        return []

    with open(data_yaml_path) as f:
        info = yaml.safe_load(f)
    source_names = info["names"]
    print(f"   Roboflow classes الأصلية: {source_names}")

    pairs = []
    for split in ("train", "valid", "test"):
        img_dir = src / split / "images"
        lbl_dir = src / split / "labels"
        if not img_dir.exists():
            continue
        for img_path in img_dir.glob("*.*"):
            lbl_path = lbl_dir / (img_path.stem + ".txt")
            new_lines = remap_yolo_labels(lbl_path, source_names, cfg["class_map"])
            if new_lines:
                pairs.append((img_path, new_lines))
    return pairs


def process_rdd2022_source(cfg: dict):
    src = cfg["path"]
    ann_dir = src / "annotations" / "xmls"
    img_dir = src / "images"
    if not ann_dir.exists():
        ann_dir = src / "Annotations"  # بعض نسخ RDD تستخدم اسم مجلد مختلف
    if not img_dir.exists():
        img_dir = src / "JPEGImages"

    pairs = []
    for xml_path in ann_dir.glob("*.xml"):
        lines, filename = voc_to_yolo_line(xml_path, cfg["class_map"])
        if not lines:
            continue
        img_path = img_dir / filename
        if not img_path.exists():
            continue
        pairs.append((img_path, lines))
    return pairs


def process_kaggle_source(cfg: dict):
    src = cfg["path"]
    img_dir = src / "images"
    ann_dir = src / "annotations"

    pairs = []
    for img_path in img_dir.glob("*.*"):
        ann_path = ann_dir / (img_path.stem + ".txt")
        lines = polygon_to_yolo_line(ann_path, cfg["class_map"])
        if lines:
            pairs.append((img_path, lines))
    return pairs


def main():
    ensure_dirs()

    all_pairs = []

    # أي مصدر format="yolo" بالقاموس (roboflow_current, roboflow_smartathon, roboflow_aegis,
    # roboflow_baka، أو أي مصدر Roboflow زيادة تضيفوه) بينعالج تلقائياً بنفس الطريقة —
    # ما في داعي تلمسوا main() لما تضيفوا مصدر Roboflow جديد، بس زيدوه بـ SOURCES فوق.
    for name, cfg in SOURCES.items():
        if cfg["format"] != "yolo":
            continue
        if not cfg["path"].exists():
            print(f"⏭️  تخطي {name} — المسار {cfg['path']} مش موجود")
            continue
        print(f"📥 معالجة {name} ...")
        pairs = process_roboflow_source(cfg)
        print(f"   ✅ {len(pairs)} صورة فيها كائنات مطابقة من {name}")
        all_pairs += [(name, p) for p in pairs]

    if SOURCES["rdd2022"]["path"].exists():
        print("📥 معالجة RDD2022 ...")
        all_pairs += [("rdd2022", p) for p in process_rdd2022_source(SOURCES["rdd2022"])]
    else:
        print("⏭️  تخطي RDD2022 — المسار مش موجود")

    if SOURCES["kaggle_rome"]["path"].exists():
        print("📥 معالجة kaggle_rome ...")
        all_pairs += [("kaggle_rome", p) for p in process_kaggle_source(SOURCES["kaggle_rome"])]
    else:
        print("⏭️  تخطي kaggle_rome — المسار مش موجود")

    print(f"\n✅ إجمالي الصور بعد الدمج: {len(all_pairs)}")

    per_class_count = {c: 0 for c in FINAL_CLASSES}

    total = len(all_pairs)
    for idx, (source_name, (img_path, lines)) in enumerate(all_pairs):
        split = split_index(idx, total)
        dst_img = OUTPUT_DIR / split / "images" / f"{source_name}_{img_path.stem}{img_path.suffix}"
        dst_lbl = OUTPUT_DIR / split / "labels" / f"{source_name}_{img_path.stem}.txt"

        shutil.copy(img_path, dst_img)
        with open(dst_lbl, "w") as f:
            f.write("\n".join(lines))

        for line in lines:
            cls_id = int(line.split()[0])
            per_class_count[FINAL_CLASSES[cls_id]] += 1

    # data.yaml النهائي
    data_yaml = {
        "path": str(OUTPUT_DIR.resolve()),
        "train": "train/images",
        "val": "val/images",
        "test": "test/images",
        "names": FINAL_CLASSES,
        "nc": len(FINAL_CLASSES),
    }
    with open(OUTPUT_DIR / "data.yaml", "w") as f:
        yaml.dump(data_yaml, f, allow_unicode=True, sort_keys=False)

    # ---- Sanity check — راجعوا هاد قبل ما تبلشوا تدريب ----
    print("\n" + "=" * 50)
    print("📊 توزيع الفئات بعد الدمج (sanity check):")
    for cls, count in per_class_count.items():
        print(f"   {cls}: {count} كائن")
    print("=" * 50)
    print(f"✅ data.yaml جاهز: {OUTPUT_DIR / 'data.yaml'}")
    print("⚠️  لو أي فئة عددها صفر أو قليل جداً مقارنة بالباقي، معناته في\n"
          "   مشكلة بالـ class_map أعلاه (اسم فئة مكتوب غلط) — راجعوه قبل التدريب.")


if __name__ == "__main__":
    main()